package com.cam2mac.sender.transport

import com.cam2mac.sender.pairing.PairingHello
import com.cam2mac.sender.pairing.PairingReply
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerializationException
import java.io.BufferedOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLSocket

sealed interface StreamStatus {
    data object Idle : StreamStatus
    data object Connecting : StreamStatus
    data object Streaming : StreamStatus
    /** Lost or could not reach the Mac; trying again. */
    data class Retrying(val reason: String) : StreamStatus
    /** Retrying cannot help: the Mac rejected this phone or presented another certificate. */
    data class Failed(val reason: String) : StreamStatus
}

/**
 * Streams HEVC access units to the Mac over TLS 1.3/TCP, using the stream framing of `FrameStreamServer`.
 *
 * One connection attempt loop runs on its own thread: resolve, connect, send the hello, then write queued frames
 * while a reader thread handles control packets. Lost connections are retried with backoff. Single use:
 * create a new client after [close].
 */
class FrameStreamClient(
    /** Blocking lookup of the Mac's address; throws [IOException] when it is not found. */
    private val resolve: () -> InetSocketAddress,
    private val trust: PinnedTrust,
    /** The hello for the next connection attempt. */
    private val hello: () -> PairingHello,
    /** The Mac accepted [hello]. */
    private val onAccepted: (PairingHello) -> Unit,
    /** The Mac or the send queue needs a keyframe. Called from client threads. */
    private val onKeyframeRequest: () -> Unit,
    private val queueCapacity: Int = 8,
    private val connectTimeoutMillis: Int = 5_000,
) {
    private val _status = MutableStateFlow<StreamStatus>(StreamStatus.Idle)
    val status: StateFlow<StreamStatus> = _status.asStateFlow()

    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN") // wait/notify monitor
    private val lock = Object()
    private val queue = ArrayDeque<ByteArray>()
    private var acceptingFrames = false
    private var waitingForKeyframe = true

    @Volatile private var running = false
    @Volatile private var socket: Socket? = null
    private var thread: Thread? = null

    fun start() {
        check(thread == null) { "FrameStreamClient is single use" }
        running = true
        thread = Thread(::runConnectionLoop, "FrameStreamClient").apply { start() }
    }

    fun close() {
        running = false
        socket?.close()
        thread?.interrupt()
        synchronized(lock) { lock.notifyAll() }
        _status.value = StreamStatus.Idle
    }

    /**
     * Queues one access unit. Frames are dropped while not connected. When the queue is full, non-keyframes are
     * dropped until the next keyframe (they would reference a dropped frame), and a keyframe is requested.
     */
    fun send(frame: ByteArray, isKeyframe: Boolean) {
        var needsKeyframe = false
        synchronized(lock) {
            if (!acceptingFrames) return
            if (isKeyframe) {
                waitingForKeyframe = false
                // Everything queued before a keyframe is obsolete once the queue backs up.
                if (queue.size >= queueCapacity) queue.clear()
            } else if (waitingForKeyframe) {
                return
            } else if (queue.size >= queueCapacity) {
                waitingForKeyframe = true
                needsKeyframe = true
            }
            if (!needsKeyframe) {
                queue.addLast(frame)
                lock.notifyAll()
            }
        }
        if (needsKeyframe) onKeyframeRequest()
    }

    private fun runConnectionLoop() {
        var attempt = 0
        while (running) {
            try {
                _status.value = StreamStatus.Connecting
                val address = resolve()
                connect(address).use { tls ->
                    authenticate(tls)
                    attempt = 0
                    stream(tls)
                }
            } catch (error: RejectedException) {
                fail(error.message ?: "The Mac rejected the connection")
                return
            } catch (error: IOException) {
                if (!running) break
                if (error.hasCause<FingerprintMismatchException>()) {
                    fail("The receiver's certificate does not match the paired Mac. Pair again.")
                    return
                }
                _status.value = StreamStatus.Retrying(error.message ?: error.javaClass.simpleName)
                try {
                    Thread.sleep(backoffMillis(attempt++))
                } catch (_: InterruptedException) {
                    break
                }
            }
        }
        if (!running) _status.value = StreamStatus.Idle
    }

    private fun fail(reason: String) {
        if (running) _status.value = StreamStatus.Failed(reason)
        running = false
    }

    private fun connect(address: InetSocketAddress): SSLSocket {
        val tcp = Socket()
        socket = tcp
        if (!running) throw IOException("Stopped")
        tcp.tcpNoDelay = true
        tcp.connect(address, connectTimeoutMillis)
        val tls = trust.sslContext().socketFactory
            .createSocket(tcp, address.hostString, address.port, true) as SSLSocket
        socket = tls
        tls.enabledProtocols = arrayOf("TLSv1.3")
        tls.soTimeout = connectTimeoutMillis
        tls.startHandshake()
        return tls
    }

    private fun authenticate(tls: SSLSocket) {
        val hello = hello()
        val output = tls.outputStream
        FramePacket.write(output, hello.encode())
        output.flush()
        val reply = try {
            PairingReply.decode(FramePacket.read(tls.inputStream, MAXIMUM_CONTROL_PACKET_BYTES))
        } catch (error: SerializationException) {
            throw IOException("Unreadable reply from the Mac", error)
        }
        if (!reply.ok) throw RejectedException(reply.reason ?: "The Mac rejected the connection")
        onAccepted(hello)
        tls.soTimeout = 0
    }

    private fun stream(tls: SSLSocket) {
        synchronized(lock) {
            queue.clear()
            waitingForKeyframe = true
            acceptingFrames = true
        }
        _status.value = StreamStatus.Streaming
        // The Mac drops connections that send no frame for 2 s, and it needs parameter sets first.
        onKeyframeRequest()

        val readerFailure = AtomicReference<IOException?>(null)
        val reader = Thread({
            try {
                while (true) {
                    val packet = FramePacket.read(tls.inputStream, MAXIMUM_CONTROL_PACKET_BYTES)
                    if (packet.size == 1 && packet[0] == KEYFRAME_REQUEST) onKeyframeRequest()
                }
            } catch (error: IOException) {
                readerFailure.set(if (error is EOFException) IOException("The Mac closed the connection") else error)
                tls.close()
                synchronized(lock) { lock.notifyAll() }
            }
        }, "FrameStreamClient-reader")
        reader.start()

        val output = BufferedOutputStream(tls.outputStream, 64 * 1024)
        try {
            while (running) {
                val frame = synchronized(lock) {
                    if (queue.isEmpty() && readerFailure.get() == null && running) lock.wait(100)
                    queue.removeFirstOrNull()
                }
                readerFailure.get()?.let { throw it }
                if (frame == null) continue
                FramePacket.write(output, frame)
                output.flush()
            }
        } catch (_: InterruptedException) {
            // close() interrupts the thread; the loop condition ends streaming.
        } finally {
            synchronized(lock) {
                acceptingFrames = false
                queue.clear()
            }
            tls.close()
        }
    }

    private class RejectedException(reason: String) : IOException(reason)

    private companion object {
        const val KEYFRAME_REQUEST: Byte = 0x01
        const val MAXIMUM_CONTROL_PACKET_BYTES = 4096

        fun backoffMillis(attempt: Int): Long = (500L shl attempt.coerceAtMost(4)).coerceAtMost(5_000L)

        inline fun <reified T : Throwable> Throwable.hasCause(): Boolean =
            generateSequence(this) { it.cause }.any { it is T }
    }
}

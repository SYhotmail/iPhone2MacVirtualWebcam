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
    /** Retrying cannot help: the Mac rejected this phone. */
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
    /**
     * Blocking, lazy lookup of addresses that may be the Mac, best first; the certificate pin picks the first
     * real one. Throws [IOException] when nothing is found.
     */
    private val candidates: () -> Sequence<InetSocketAddress>,
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

    private val queue = FrameQueue(queueCapacity)

    @Volatile private var running = false
    /** The current connection's TCP socket. Other threads close this one, never the TLS socket: no TLS I/O. */
    @Volatile private var tcpSocket: Socket? = null
    private var thread: Thread? = null

    fun start() {
        check(thread == null) { "FrameStreamClient is single use" }
        running = true
        thread = Thread(::runConnectionLoop, "FrameStreamClient").apply { start() }
    }

    /** Safe on the main thread: closes the TCP socket without TLS I/O, so it neither blocks nor touches the network. */
    fun close() {
        running = false
        runCatching { tcpSocket?.close() }
        thread?.interrupt()
        queue.wake()
        _status.value = StreamStatus.Idle
    }

    /**
     * Queues one access unit. Frames are dropped while not connected. When the queue is full, non-keyframes are
     * dropped until the next keyframe (they would reference a dropped frame), and a keyframe is requested.
     */
    fun send(frame: ByteArray, isKeyframe: Boolean) {
        if (queue.offer(frame, isKeyframe)) onKeyframeRequest()
    }

    private fun runConnectionLoop() {
        var attempt = 0
        while (running) {
            try {
                _status.value = StreamStatus.Connecting
                connectToPinnedReceiver().use { tls ->
                    authenticate(tls)
                    attempt = 0
                    stream(tls)
                }
            } catch (error: RejectedException) {
                fail(error.message ?: "The Mac rejected the connection")
                return
            } catch (error: Exception) {
                if (error is InterruptedException || !running) break
                // A mismatch may be another Mac with the same name while ours is offline, so keep trying.
                val reason = if (error.hasCause<FingerprintMismatchException>()) {
                    "Found a Mac with this name, but not the paired one. If you reset the Mac app, pair again."
                } else {
                    error.message ?: error.javaClass.simpleName
                }
                _status.value = StreamStatus.Retrying(reason)
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

    /** Connects to the first candidate whose TLS handshake passes the certificate pin. */
    private fun connectToPinnedReceiver(): SSLSocket {
        var failure: IOException? = null
        // Prefer reporting a mismatch: it tells the user a same-named Mac was found.
        fun record(error: IOException) {
            if (failure?.hasCause<FingerprintMismatchException>() != true) failure = error
        }
        val addresses = candidates().iterator()
        while (true) {
            val address = try {
                if (!addresses.hasNext()) break
                addresses.next()
            } catch (error: IOException) {
                record(error)
                break
            }
            try {
                return connect(address)
            } catch (error: IOException) {
                if (!running) throw error
                record(error)
            }
        }
        throw failure ?: IOException("Could not find the Mac on this network")
    }

    private fun connect(address: InetSocketAddress): SSLSocket {
        val tcp = Socket()
        tcpSocket = tcp
        try {
            if (!running) throw IOException("Stopped")
            tcp.tcpNoDelay = true
            tcp.connect(address, connectTimeoutMillis)
            val tls = trust.sslContext().socketFactory
                .createSocket(tcp, address.hostString, address.port, true) as SSLSocket
            tls.enabledProtocols = arrayOf("TLSv1.3")
            tls.soTimeout = connectTimeoutMillis
            tls.startHandshake()
            return tls
        } catch (error: IOException) {
            tcp.close()
            throw error
        }
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
        if (!reply.ok) {
            val reason = reply.reason ?: "The Mac rejected the connection"
            // The Mac app is starting up or between sessions: worth retrying.
            if (reason == NOT_ACCEPTING_REASON) throw IOException(reason)
            throw RejectedException(reason)
        }
        onAccepted(hello)
        tls.soTimeout = 0
    }

    private fun stream(tls: SSLSocket) {
        queue.open()
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
                // Unblocks a writer stuck on a full send buffer.
                runCatching { tcpSocket?.close() }
                queue.wake()
            }
        }, "FrameStreamClient-reader")
        reader.start()

        val output = BufferedOutputStream(tls.outputStream, 64 * 1024)
        try {
            while (running) {
                readerFailure.get()?.let { throw it }
                val frame = queue.poll(100)
                readerFailure.get()?.let { throw it }
                if (frame == null) continue
                FramePacket.write(output, frame)
                output.flush()
            }
        } catch (_: InterruptedException) {
            // close() interrupts the thread; the loop condition ends streaming.
        } finally {
            queue.close()
            tls.close()
        }
    }

    private class RejectedException(reason: String) : IOException(reason)

    private companion object {
        const val KEYFRAME_REQUEST: Byte = 0x01
        const val MAXIMUM_CONTROL_PACKET_BYTES = 4096
        /** `FrameStreamServer` sends this while it has no hello authorizer yet. */
        const val NOT_ACCEPTING_REASON = "Receiver is not accepting connections"

        fun backoffMillis(attempt: Int): Long = (500L shl attempt.coerceAtMost(4)).coerceAtMost(5_000L)

        inline fun <reified T : Throwable> Throwable.hasCause(): Boolean =
            generateSequence(this) { it.cause }.any { it is T }
    }
}

package com.cam2mac.sender.transport

import com.cam2mac.sender.pairing.PairingHello
import com.cam2mac.sender.pairing.PairingReply
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.SerializationException
import tech.kwik.core.QuicClientConnection
import tech.kwik.core.QuicStream
import tech.kwik.core.impl.QuicConnectionImpl
import java.io.EOFException
import java.io.IOException
import java.net.InetSocketAddress
import java.time.Duration
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

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
 * Streams HEVC access units to the Mac like the iPhone app does: one QUIC connection (ALPN `camera-lan-stream`)
 * with a bidirectional stream for pairing and control messages (`FramePacket` framing) and QUIC datagrams
 * (RFC 9221) for video, split with [VideoDatagram].
 *
 * One connection loop runs on its own thread: resolve, connect, check the certificate pin, send the hello, then
 * read control packets until the connection ends. Video is sent from the caller's thread by [send]. Lost
 * connections are retried with backoff. Single use: create a new client after [close].
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
    /** The Mac needs a keyframe (after a loss, or because streaming just started). Called from client threads. */
    private val onKeyframeRequest: () -> Unit,
    private val connectTimeoutMillis: Long = 5_000,
    /** See [SendBacklog]; tests raise it to isolate other behavior. */
    private val backlogLimitBytes: Long = SendBacklog.DEFAULT_LIMIT_BYTES,
) {
    private val _status = MutableStateFlow<StreamStatus>(StreamStatus.Idle)
    val status: StateFlow<StreamStatus> = _status.asStateFlow()

    @Volatile private var running = false
    /** The current connection; other threads only call its non-blocking `close()`. */
    @Volatile private var connection: QuicClientConnection? = null
    /** Set while authenticated; [send] writes datagrams to it. */
    @Volatile private var video: VideoSender? = null
    private var thread: Thread? = null

    fun start() {
        check(thread == null) { "FrameStreamClient is single use" }
        running = true
        thread = Thread(::runConnectionLoop, "FrameStreamClient").apply { start() }
    }

    /** Safe on the main thread: Kwik's `close()` only queues a CONNECTION_CLOSE for its sender thread. */
    fun close() {
        running = false
        video = null
        runCatching { connection?.close() }
        thread?.interrupt()
        _status.value = StreamStatus.Idle
    }

    /**
     * Sends one access unit as datagrams. Frames are dropped while not connected, after (re)connecting until the
     * first keyframe (the Mac can't decode deltas without it), and while Kwik's send queue is backed up
     * ([SendBacklog], which then requests a keyframe through `onKeyframeRequest`).
     */
    fun send(frame: ByteArray, isKeyframe: Boolean) {
        video?.send(frame, isKeyframe)
    }

    private fun runConnectionLoop() {
        var attempt = 0
        while (running) {
            try {
                _status.value = StreamStatus.Connecting
                val quic = connectToPinnedReceiver()
                try {
                    val control = authenticate(quic)
                    attempt = 0
                    stream(quic, control)
                } finally {
                    video = null
                    quic.close()
                }
            } catch (error: RejectedException) {
                fail(error.message ?: "The Mac rejected the connection")
                return
            } catch (error: Exception) {
                // RuntimeException included: Kwik reports some failures unchecked, and none may kill the loop.
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

    /** Connects to the first candidate whose certificate passes the pin. */
    private fun connectToPinnedReceiver(): QuicClientConnection {
        var failure: Exception? = null
        // Prefer reporting a mismatch: it tells the user a same-named Mac was found.
        fun record(error: Exception) {
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
            } catch (error: Exception) {
                if (!running || error is InterruptedException) throw error
                record(error)
            }
        }
        throw failure ?: IOException("Could not find the Mac on this network")
    }

    private fun connect(address: InetSocketAddress): QuicClientConnection {
        val quic = QuicClientConnection.newBuilder()
            .host(address.address.hostAddress)
            .port(address.port)
            .applicationProtocol(APPLICATION_PROTOCOL)
            .enableDatagramExtension()
            // Kwik has no hook for a custom trust manager, so the certificate is pinned right after the handshake
            // instead (below). This is safe: the pin compares the whole leaf certificate, whose key signed the
            // handshake (TLS 1.3 CertificateVerify, which Kwik verifies even without a certificate check), and
            // the hello with the pairing token or secret is only sent after the pin matched.
            .noServerCertificateCheck()
            .connectTimeout(Duration.ofMillis(connectTimeoutMillis))
            .maxIdleTimeout(Duration.ofMillis(IDLE_TIMEOUT_MILLIS))
            .build()
        connection = quic
        try {
            if (!running) throw IOException("Stopped")
            quic.connect()
            trust.check(quic.serverCertificateChain)
            return quic
        } catch (error: Exception) {
            quic.close()
            throw error
        }
    }

    private fun authenticate(quic: QuicClientConnection): QuicStream {
        val hello = hello()
        val control = quic.createStream(true)
        FramePacket.write(control.outputStream, hello.encode())
        control.outputStream.flush()
        val reply = withReplyDeadline(quic) {
            try {
                PairingReply.decode(FramePacket.read(control.inputStream, MAXIMUM_CONTROL_PACKET_BYTES))
            } catch (error: SerializationException) {
                throw IOException("Unreadable reply from the Mac", error)
            } catch (error: IOException) {
                throw if (error is EOFException) IOException("The Mac closed the connection") else error
            }
        }
        if (!reply.ok) {
            val reason = reply.reason ?: "The Mac rejected the connection"
            // The Mac app is starting up or between sessions: worth retrying.
            if (reason == NOT_ACCEPTING_REASON) throw IOException(reason)
            throw RejectedException(reason)
        }
        onAccepted(hello)
        return control
    }

    /**
     * Runs [read] with a deadline that closes [quic] when it passes, since Kwik stream reads have no timeout.
     * Whichever comes first wins: a reply that arrived in time is never followed by a late close.
     */
    private fun <T> withReplyDeadline(quic: QuicClientConnection, read: () -> T): T {
        val decided = AtomicBoolean(false)
        val timer = Executors.newSingleThreadScheduledExecutor { Thread(it, "FrameStreamClient-deadline").apply { isDaemon = true } }
        try {
            timer.schedule({ if (decided.compareAndSet(false, true)) quic.close() }, connectTimeoutMillis, TimeUnit.MILLISECONDS)
            val result = try {
                read()
            } catch (error: IOException) {
                if (decided.compareAndSet(false, true)) throw error
                throw IOException("The Mac did not answer the hello", error)
            }
            if (!decided.compareAndSet(false, true)) throw IOException("The Mac did not answer the hello")
            return result
        } finally {
            timer.shutdownNow()
        }
    }

    /** Reads control packets until the connection ends; video goes out through [send] meanwhile. */
    private fun stream(quic: QuicClientConnection, control: QuicStream) {
        video = VideoSender(quic, SendBacklog(backlogLimitBytes, quic.stats.bytesSent()), onKeyframeRequest)
        _status.value = StreamStatus.Streaming
        // The Mac drops connections that send no frame for 2 s, and it needs parameter sets first.
        onKeyframeRequest()
        try {
            while (running) {
                val packet = FramePacket.read(control.inputStream, MAXIMUM_CONTROL_PACKET_BYTES)
                if (packet.size == 1 && packet[0] == KEYFRAME_REQUEST) onKeyframeRequest()
            }
        } catch (error: IOException) {
            if (!running) return
            throw if (error is EOFException) IOException("The Mac closed the connection") else error
        }
    }

    /** Video for one connection: frame IDs start at 0, and the first frame sent is a keyframe. */
    private class VideoSender(
        quic: QuicClientConnection,
        private val backlog: SendBacklog,
        private val onKeyframeRequest: () -> Unit,
    ) {
        /** Kwik's builder always returns `QuicClientConnectionImpl`; [OrderedDatagramSender] needs its send API. */
        private val quic = quic as QuicConnectionImpl
        private val datagrams = OrderedDatagramSender(this.quic)
        private var nextFrameID = 0

        @Synchronized
        fun send(frame: ByteArray, isKeyframe: Boolean) {
            if (!quic.canSendDatagram()) return
            // maxDatagramDataSize() doesn't subtract the 16-byte AEAD tag; a datagram that doesn't fit is
            // silently never sent.
            val maximumSize = minOf(quic.maxDatagramDataSize() - AEAD_TAG_BYTES, VideoDatagram.MAXIMUM_DATAGRAM_SIZE)
            val chunks = VideoDatagram.chunks(frame, nextFrameID, isKeyframe, maximumSize)
            if (chunks.isEmpty()) return
            when (backlog.decide(chunks.sumOf { it.size }, isKeyframe, quic.stats.bytesSent())) {
                SendBacklog.Decision.DROP -> return
                SendBacklog.Decision.DROP_AND_REQUEST_KEYFRAME -> {
                    onKeyframeRequest()
                    return
                }
                SendBacklog.Decision.SEND -> Unit
            }
            nextFrameID++ // Wraps like the Mac's UInt32 frame IDs.
            try {
                chunks.forEach(datagrams::send)
            } catch (_: RuntimeException) {
                // The connection is closing; the connection loop reports it.
            }
        }
    }

    private class RejectedException(reason: String) : IOException(reason)

    private companion object {
        const val APPLICATION_PROTOCOL = "camera-lan-stream"
        const val KEYFRAME_REQUEST: Byte = 0x01
        const val MAXIMUM_CONTROL_PACKET_BYTES = 4096
        const val AEAD_TAG_BYTES = 16
        /** Notices a Mac that vanished; video keeps the connection busy, so this never fires while streaming. */
        const val IDLE_TIMEOUT_MILLIS = 5_000L
        /** `FrameStreamServer` sends this while it has no hello authorizer yet. */
        const val NOT_ACCEPTING_REASON = "Receiver is not accepting connections"

        fun backoffMillis(attempt: Int): Long = (500L shl attempt.coerceAtMost(4)).coerceAtMost(5_000L)

        inline fun <reified T : Throwable> Throwable.hasCause(): Boolean =
            generateSequence(this) { it.cause }.any { it is T }
    }
}

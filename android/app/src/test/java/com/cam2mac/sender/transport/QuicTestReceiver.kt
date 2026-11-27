package com.cam2mac.sender.transport

import tech.kwik.core.QuicConnection
import tech.kwik.core.QuicStream
import tech.kwik.core.log.NullLogger
import tech.kwik.core.server.ApplicationProtocolConnection
import tech.kwik.core.server.ApplicationProtocolConnectionFactory
import tech.kwik.core.server.ServerConnectionConfig
import tech.kwik.core.server.ServerConnector
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** An in-process Kwik QUIC server speaking the Mac's ALPN, standing in for the Mac's QUIC listener. */
class QuicTestReceiver(identity: TestIdentity = TestIdentity()) : AutoCloseable {
    /** One accepted connection with what the client sent on it. */
    class Peer(val connection: QuicConnection) {
        val streams = LinkedBlockingQueue<QuicStream>()
        val datagrams = LinkedBlockingQueue<ByteArray>()

        /** The control stream: the first stream the client opens. */
        fun control(): QuicStream = checkNotNull(streams.poll(5, TimeUnit.SECONDS)) { "No control stream" }
    }

    private val socket = DatagramSocket(0, InetAddress.getLoopbackAddress())
    val address = InetSocketAddress(InetAddress.getLoopbackAddress(), socket.localPort)
    val peers = LinkedBlockingQueue<Peer>()

    private val connector = ServerConnector.builder()
        .withPort(socket.localPort) // Required even with a socket; the socket wins.
        .withSocket(socket)
        .withSupportedVersion(QuicConnection.QuicVersion.V1)
        .withLogger(NullLogger())
        .withKeyStore(identity.keyStore(), TestIdentity.ALIAS, CharArray(0), "secp256r1")
        .withConfiguration(
            ServerConnectionConfig.builder()
                .maxIdleTimeoutInSeconds(30)
                .maxOpenPeerInitiatedBidirectionalStreams(4)
                .maxBidirectionalStreamBufferSize(1_000_000)
                .maxConnectionBufferSize(10_000_000)
                .build()
        )
        .build()
        .apply {
            registerApplicationProtocol("camera-lan-stream", object : ApplicationProtocolConnectionFactory {
                override fun createConnection(protocol: String, connection: QuicConnection): ApplicationProtocolConnection {
                    val peer = Peer(connection)
                    connection.setDatagramHandler { peer.datagrams.put(it) }
                    peers.put(peer)
                    return object : ApplicationProtocolConnection {
                        override fun acceptPeerInitiatedStream(stream: QuicStream) {
                            peer.streams.put(stream)
                        }
                    }
                }

                override fun enableDatagramExtension() = true
                override fun maxConcurrentPeerInitiatedBidirectionalStreams() = 4
            })
            start()
        }

    fun accept(): Peer = checkNotNull(peers.poll(10, TimeUnit.SECONDS)) { "No connection" }

    override fun close() {
        connector.close()
        socket.close()
    }
}

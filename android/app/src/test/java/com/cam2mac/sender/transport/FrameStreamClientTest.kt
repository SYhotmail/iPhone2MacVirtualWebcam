package com.cam2mac.sender.transport

import com.cam2mac.sender.pairing.PairingHello
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLServerSocket

class FrameStreamClientTest {
    private val mac = TestIdentity()
    private val server = mac.serverContext().serverSocketFactory
        .createServerSocket(0, 1, InetAddress.getLoopbackAddress()) as SSLServerSocket
    private val clientID = UUID.randomUUID()
    private val secret = ByteArray(32) { 7 }
    private var client: FrameStreamClient? = null

    @After
    fun tearDown() {
        client?.close()
        server.close()
    }

    private fun makeClient(
        fingerprint: ByteArray = mac.fingerprint,
        hello: () -> PairingHello = { PairingHello.hello(clientID, secret) },
        onAccepted: (PairingHello) -> Unit = {},
        onKeyframeRequest: () -> Unit = {},
        candidates: () -> Sequence<InetSocketAddress> = { sequenceOf(serverAddress(server)) },
    ) = FrameStreamClient(
        candidates = candidates,
        trust = PinnedTrust(fingerprint),
        hello = hello,
        onAccepted = onAccepted,
        onKeyframeRequest = onKeyframeRequest,
    ).also { client = it }

    private fun serverAddress(server: SSLServerSocket) = InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort)

    private fun Socket.readHello(): JsonObject {
        soTimeout = 5_000
        val payload = FramePacket.read(getInputStream(), 4096)
        return Json.parseToJsonElement(payload.toString(Charsets.UTF_8)).jsonObject
    }

    private fun Socket.reply(json: String) {
        FramePacket.write(getOutputStream(), json.toByteArray())
        getOutputStream().flush()
    }

    @Test
    fun streamsFramesAndHandlesKeyframeRequests() {
        val keyframeRequests = Semaphore(0)
        val keyframe = byteArrayOf(0, 0, 0, 1, 0x40, 0x01, 0, 0, 0, 1, 0x26, 0x01)
        lateinit var streamClient: FrameStreamClient
        streamClient = makeClient(onKeyframeRequest = {
            keyframeRequests.release()
            // Like the encoder: answer each request with a keyframe.
            streamClient.send(keyframe, isKeyframe = true)
        })
        streamClient.start()

        server.accept().use { socket ->
            val hello = socket.readHello()
            assertEquals("hello", hello["type"]?.jsonPrimitive?.content)
            assertEquals(clientID.toString().uppercase(), hello["clientID"]?.jsonPrimitive?.content)
            socket.reply("""{"ok":true}""")

            // Streaming starts with a keyframe request so the Mac gets parameter sets within its 2 s timeout.
            assertTrue(keyframeRequests.tryAcquire(5, TimeUnit.SECONDS))
            assertArrayEquals(keyframe, FramePacket.read(socket.getInputStream(), Int.MAX_VALUE))
            runBlocking { withTimeout(5_000) { streamClient.status.first { it == StreamStatus.Streaming } } }

            streamClient.send(byteArrayOf(0, 0, 0, 1, 0x02, 0x01), isKeyframe = false)
            assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x02, 0x01), FramePacket.read(socket.getInputStream(), Int.MAX_VALUE))

            socket.reply("\u0001")
            assertTrue("[0x01] did not trigger a keyframe request", keyframeRequests.tryAcquire(5, TimeUnit.SECONDS))
            assertArrayEquals(keyframe, FramePacket.read(socket.getInputStream(), Int.MAX_VALUE))
        }
    }

    @Test
    fun switchesToHelloAfterPairing() {
        val token = ByteArray(16) { 1 }
        val accepted = LinkedBlockingQueue<PairingHello>()
        var pendingToken: ByteArray? = token
        makeClient(
            hello = {
                pendingToken?.let { PairingHello.pair(it, clientID, secret, "Test Phone") }
                    ?: PairingHello.hello(clientID, secret)
            },
            onAccepted = { hello ->
                if (hello.kind == PairingHello.Kind.PAIR) pendingToken = null
                accepted.put(hello)
            },
        ).start()

        server.accept().use { socket ->
            val hello = socket.readHello()
            assertEquals("pair", hello["type"]?.jsonPrimitive?.content)
            assertEquals("Test Phone", hello["name"]?.jsonPrimitive?.content)
            socket.reply("""{"ok":true}""")
            assertEquals(PairingHello.Kind.PAIR, accepted.poll(5, TimeUnit.SECONDS)?.kind)
        }
        // The server dropped the connection; the client reconnects with a plain hello.
        server.accept().use { socket ->
            assertEquals("hello", socket.readHello()["type"]?.jsonPrimitive?.content)
        }
    }

    @Test
    fun rejectionFailsWithoutRetrying() {
        val streamClient = makeClient()
        streamClient.start()
        server.accept().use { socket ->
            socket.readHello()
            socket.reply("""{"ok":false,"reason":"Unknown client"}""")
        }
        val status = runBlocking {
            withTimeout(5_000) { streamClient.status.first { it is StreamStatus.Failed } }
        }
        assertEquals(StreamStatus.Failed("Unknown client"), status)
    }

    @Test
    fun notAcceptingConnectionsIsRetried() {
        makeClient().start()
        server.accept().use { socket ->
            socket.readHello()
            socket.reply("""{"ok":false,"reason":"Receiver is not accepting connections"}""")
        }
        // Not a final failure: the client comes back with another hello.
        server.accept().use { socket ->
            assertEquals("hello", socket.readHello()["type"]?.jsonPrimitive?.content)
        }
    }

    @Test
    fun certificateMismatchKeepsRetrying() {
        val streamClient = makeClient(fingerprint = TestIdentity().fingerprint)
        streamClient.start()
        server.soTimeout = 5_000
        runCatching { server.accept().use { (it as javax.net.ssl.SSLSocket).startHandshake() } }
        // Another Mac with the same name may answer while the paired one is offline: not a final failure.
        val status = runBlocking {
            withTimeout(5_000) { streamClient.status.first { it is StreamStatus.Retrying } }
        }
        assertTrue(status.toString(), (status as StreamStatus.Retrying).reason.contains("not the paired one"))
    }

    @Test
    fun skipsSameNamedReceiverWithAnotherCertificate() {
        val impostor = TestIdentity().serverContext().serverSocketFactory
            .createServerSocket(0, 1, InetAddress.getLoopbackAddress()) as SSLServerSocket
        impostor.use {
            val impostorThread = Thread {
                runCatching { impostor.accept().use { (it as javax.net.ssl.SSLSocket).startHandshake() } }
            }.apply { start() }
            // The impostor holds the exact name; the paired Mac was renamed by Bonjour and comes second.
            makeClient(candidates = { sequenceOf(serverAddress(impostor), serverAddress(server)) }).start()

            server.accept().use { socket ->
                assertEquals("hello", socket.readHello()["type"]?.jsonPrimitive?.content)
            }
            impostorThread.join(5_000)
        }
    }
}

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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.kwik.core.QuicStream
import java.net.InetSocketAddress
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

class FrameStreamClientTest {
    private val mac = TestIdentity()
    private val receiver = QuicTestReceiver(mac)
    private val clientID = UUID.randomUUID()
    private val secret = ByteArray(32) { 7 }
    private var client: FrameStreamClient? = null

    @After
    fun tearDown() {
        client?.close()
        receiver.close()
    }

    private fun makeClient(
        fingerprint: ByteArray = mac.fingerprint,
        hello: () -> PairingHello = { PairingHello.hello(clientID, secret) },
        onAccepted: (PairingHello) -> Unit = {},
        onKeyframeRequest: () -> Unit = {},
        candidates: () -> Sequence<InetSocketAddress> = { sequenceOf(receiver.address) },
        backlogLimitBytes: Long = SendBacklog.DEFAULT_LIMIT_BYTES,
    ) = FrameStreamClient(
        candidates = candidates,
        trust = PinnedTrust(fingerprint),
        hello = hello,
        onAccepted = onAccepted,
        onKeyframeRequest = onKeyframeRequest,
        backlogLimitBytes = backlogLimitBytes,
    ).also { client = it }

    /** Accepts the next connection, answers its hello with ok and waits until the client streams on it. */
    private fun acceptStreaming(keyframeRequests: Semaphore): QuicTestReceiver.Peer {
        val peer = receiver.accept()
        val control = peer.control()
        control.readHello()
        control.reply("""{"ok":true}""")
        // The client requests a keyframe as soon as it can send video on this connection.
        assertTrue(keyframeRequests.tryAcquire(5, TimeUnit.SECONDS))
        return peer
    }

    private fun InOrderReassembler.assertNext(frameID: Int, isKeyframe: Boolean, data: ByteArray) {
        val frame = checkNotNull(next()) { "frame $frameID never completed" }
        assertEquals(frameID, frame.frameID)
        assertEquals(isKeyframe, frame.isKeyframe)
        assertArrayEquals(data, frame.data)
    }

    private fun QuicStream.readHello(): JsonObject {
        val payload = FramePacket.read(inputStream, 4096)
        return Json.parseToJsonElement(payload.toString(Charsets.UTF_8)).jsonObject
    }

    private fun QuicStream.reply(payload: ByteArray) {
        FramePacket.write(outputStream, payload)
        outputStream.flush()
    }

    private fun QuicStream.reply(json: String) = reply(json.toByteArray())

    @Test
    fun streamsDatagramsAndHandlesKeyframeRequests() {
        val keyframeRequests = Semaphore(0)
        val streamClient = makeClient(onKeyframeRequest = { keyframeRequests.release() })
        streamClient.start()

        val peer = receiver.accept()
        val control = peer.control()
        val hello = control.readHello()
        assertEquals("hello", hello["type"]?.jsonPrimitive?.content)
        assertEquals(clientID.toString().uppercase(), hello["clientID"]?.jsonPrimitive?.content)
        control.reply("""{"ok":true}""")

        // Streaming starts with a keyframe request so the Mac gets parameter sets within its 2 s timeout.
        assertTrue(keyframeRequests.tryAcquire(5, TimeUnit.SECONDS))
        runBlocking { withTimeout(5_000) { streamClient.status.first { it == StreamStatus.Streaming } } }

        // Deltas before the first keyframe are useless to the Mac and dropped.
        streamClient.send(byteArrayOf(0, 0, 0, 1, 0x02, 0x01), isKeyframe = false)
        val keyframe = ByteArray(3_000) { it.toByte() }
        streamClient.send(keyframe, isKeyframe = true)
        val delta = byteArrayOf(0, 0, 0, 1, 0x02, 0x01, 0x55)
        streamClient.send(delta, isKeyframe = false)
        // Had the leading delta gone out, it would be frame 0.
        val frames = InOrderReassembler(peer.datagrams)
        frames.assertNext(frameID = 0, isKeyframe = true, data = keyframe)
        frames.assertNext(frameID = 1, isKeyframe = false, data = delta)

        control.reply(byteArrayOf(0x01))
        assertTrue("[0x01] did not trigger a keyframe request", keyframeRequests.tryAcquire(5, TimeUnit.SECONDS))
    }

    @Test
    fun framesArriveInOrderWhenTheSendQueueBacksUp() {
        val keyframeRequests = Semaphore(0)
        // No backlog dropping: this checks the order Kwik puts datagrams on the wire.
        val streamClient = makeClient(onKeyframeRequest = { keyframeRequests.release() }, backlogLimitBytes = 1L shl 40)
        streamClient.start()
        val peer = acceptStreaming(keyframeRequests)

        // Two IDRs are far beyond the initial congestion window, so most datagrams wait in Kwik's queue. The small
        // deltas after them (less than one chunk each) must not slip in front of a queued full-size chunk.
        val sizes = listOf(150_000, 150_000) + List(20) { 200 + it * 97 }
        sizes.forEachIndexed { index, size ->
            streamClient.send(ByteArray(size) { (it % 251).toByte() }, isKeyframe = index < 2)
        }

        val frames = InOrderReassembler(peer.datagrams)
        val completed = generateSequence { frames.next(timeoutMillis = 3_000) }.take(sizes.size).map { it.frameID }.toList()
        assertEquals(sizes.indices.toList(), completed)
    }

    @Test
    fun reconnectRestartsFrameIDsWithAKeyframe() {
        val keyframeRequests = Semaphore(0)
        val streamClient = makeClient(onKeyframeRequest = { keyframeRequests.release() })
        streamClient.start()
        val keyframe = ByteArray(3_000) { it.toByte() }
        val delta = byteArrayOf(0, 0, 0, 1, 0x02, 0x01, 0x55)

        val first = acceptStreaming(keyframeRequests)
        streamClient.send(keyframe, isKeyframe = true)
        streamClient.send(delta, isKeyframe = false)
        InOrderReassembler(first.datagrams).run {
            assertNext(frameID = 0, isKeyframe = true, data = keyframe)
            assertNext(frameID = 1, isKeyframe = false, data = delta)
        }
        first.connection.close()

        val second = acceptStreaming(keyframeRequests)
        streamClient.send(delta, isKeyframe = false) // Dropped: the new connection starts with a keyframe.
        streamClient.send(keyframe, isKeyframe = true)
        streamClient.send(delta, isKeyframe = false)
        InOrderReassembler(second.datagrams).run {
            assertNext(frameID = 0, isKeyframe = true, data = keyframe)
            assertNext(frameID = 1, isKeyframe = false, data = delta)
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

        val first = receiver.accept()
        val control = first.control()
        val hello = control.readHello()
        assertEquals("pair", hello["type"]?.jsonPrimitive?.content)
        assertEquals("Test Phone", hello["name"]?.jsonPrimitive?.content)
        control.reply("""{"ok":true}""")
        assertEquals(PairingHello.Kind.PAIR, accepted.poll(5, TimeUnit.SECONDS)?.kind)
        first.connection.close()

        // The Mac dropped the connection; the client reconnects with a plain hello.
        assertEquals("hello", receiver.accept().control().readHello()["type"]?.jsonPrimitive?.content)
    }

    @Test
    fun rejectionFailsWithoutRetrying() {
        val streamClient = makeClient()
        streamClient.start()
        val control = receiver.accept().control()
        control.readHello()
        control.reply("""{"ok":false,"reason":"Unknown client"}""")
        val status = runBlocking {
            withTimeout(5_000) { streamClient.status.first { it is StreamStatus.Failed } }
        }
        assertEquals(StreamStatus.Failed("Unknown client"), status)
    }

    @Test
    fun notAcceptingConnectionsIsRetried() {
        makeClient().start()
        val control = receiver.accept().control()
        control.readHello()
        control.reply("""{"ok":false,"reason":"Receiver is not accepting connections"}""")
        // Not a final failure: the client comes back with another hello.
        assertEquals("hello", receiver.accept().control().readHello()["type"]?.jsonPrimitive?.content)
    }

    @Test
    fun certificateMismatchSendsNoHelloAndKeepsRetrying() {
        val streamClient = makeClient(fingerprint = TestIdentity().fingerprint)
        streamClient.start()
        // Another Mac with the same name may answer while the paired one is offline: not a final failure.
        val status = runBlocking {
            withTimeout(5_000) { streamClient.status.first { it is StreamStatus.Retrying } }
        }
        assertTrue(status.toString(), (status as StreamStatus.Retrying).reason.contains("not the paired one"))
        // The secret never reaches a Mac that failed the pin.
        val peer = receiver.accept()
        assertNull(peer.streams.poll(500, TimeUnit.MILLISECONDS))
    }

    @Test
    fun skipsReceiverWithAnotherCertificate() {
        QuicTestReceiver(TestIdentity()).use { impostor ->
            makeClient(candidates = { sequenceOf(impostor.address, receiver.address) }).start()
            assertEquals("hello", receiver.accept().control().readHello()["type"]?.jsonPrimitive?.content)
            assertNull(impostor.accept().streams.poll(100, TimeUnit.MILLISECONDS))
        }
    }
}

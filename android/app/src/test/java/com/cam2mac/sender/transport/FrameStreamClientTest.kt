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
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.nio.ByteBuffer
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
    ) = FrameStreamClient(
        candidates = candidates,
        trust = PinnedTrust(fingerprint),
        hello = hello,
        onAccepted = onAccepted,
        onKeyframeRequest = onKeyframeRequest,
    ).also { client = it }

    private fun QuicStream.readHello(): JsonObject {
        val payload = FramePacket.read(inputStream, 4096)
        return Json.parseToJsonElement(payload.toString(Charsets.UTF_8)).jsonObject
    }

    private fun QuicStream.reply(payload: ByteArray) {
        FramePacket.write(outputStream, payload)
        outputStream.flush()
    }

    private fun QuicStream.reply(json: String) = reply(json.toByteArray())

    /** Datagrams of frames not asked for yet; Kwik may hand datagrams over out of order. */
    private val pendingDatagrams = mutableListOf<ByteArray>()

    private fun ByteArray.frameID() = ByteBuffer.wrap(this, 2, 4).int
    private fun ByteArray.chunkIndex() = ByteBuffer.wrap(this, 6, 2).short.toInt() and 0xFFFF
    private fun ByteArray.chunkCount() = ByteBuffer.wrap(this, 8, 2).short.toInt() and 0xFFFF

    /** Collects the datagrams of frame [frameID], checks their headers and returns the frame. */
    private fun LinkedBlockingQueue<ByteArray>.receiveFrame(frameID: Int, isKeyframe: Boolean): ByteArray {
        fun chunks() = pendingDatagrams.filter { it.frameID() == frameID }
        while (chunks().let { it.isEmpty() || it.size < it.first().chunkCount() }) {
            pendingDatagrams += checkNotNull(poll(5, TimeUnit.SECONDS)) { "Frame $frameID is incomplete" }
        }
        val chunks = chunks().sortedBy { it.chunkIndex() }
        pendingDatagrams -= chunks.toSet()
        val frame = ByteArrayOutputStream()
        chunks.forEachIndexed { index, datagram ->
            assertTrue("datagram of ${datagram.size} bytes", datagram.size <= VideoDatagram.MAXIMUM_DATAGRAM_SIZE)
            assertEquals(VideoDatagram.VERSION, datagram[0])
            assertEquals(if (isKeyframe) 1.toByte() else 0.toByte(), datagram[1])
            assertEquals(index, datagram.chunkIndex())
            assertEquals(chunks.size, datagram.chunkCount())
            frame.write(datagram, VideoDatagram.HEADER_BYTE_COUNT, datagram.size - VideoDatagram.HEADER_BYTE_COUNT)
        }
        return frame.toByteArray()
    }

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
        assertArrayEquals(keyframe, peer.datagrams.receiveFrame(frameID = 0, isKeyframe = true))
        assertArrayEquals(delta, peer.datagrams.receiveFrame(frameID = 1, isKeyframe = false))
        assertTrue("the leading delta was sent", pendingDatagrams.isEmpty() && peer.datagrams.isEmpty())

        control.reply(byteArrayOf(0x01))
        assertTrue("[0x01] did not trigger a keyframe request", keyframeRequests.tryAcquire(5, TimeUnit.SECONDS))
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

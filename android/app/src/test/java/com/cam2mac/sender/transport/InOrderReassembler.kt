package com.cam2mac.sender.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Rebuilds frames from [VideoDatagram] chunks the way the Mac's `FrameReassembler` delivers them: strictly in
 * frame-ID order. Datagrams of a frame not newer than the last completed one are dropped, and completing a frame
 * abandons older partial ones. Checks every header on the way.
 */
class InOrderReassembler(private val datagrams: LinkedBlockingQueue<ByteArray>) {
    class Frame(val frameID: Int, val isKeyframe: Boolean, val data: ByteArray)

    private class Partial(val chunkCount: Int, val isKeyframe: Boolean) {
        val chunks = arrayOfNulls<ByteArray>(chunkCount)
        var received = 0
    }

    private val partial = mutableMapOf<Int, Partial>()
    private var lastFrameID: Int? = null

    /** The next frame the Mac would deliver, or null if none completes within [timeoutMillis]. */
    fun next(timeoutMillis: Long = 5_000): Frame? {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)
        while (true) {
            val left = deadline - System.nanoTime()
            val datagram = (if (left > 0) datagrams.poll(left, TimeUnit.NANOSECONDS) else null) ?: return null
            add(datagram)?.let { return it }
        }
    }

    private fun add(datagram: ByteArray): Frame? {
        assertTrue("datagram of ${datagram.size} bytes", datagram.size in (VideoDatagram.HEADER_BYTE_COUNT + 1)..VideoDatagram.MAXIMUM_DATAGRAM_SIZE)
        val header = ByteBuffer.wrap(datagram)
        assertEquals(VideoDatagram.VERSION, header.get())
        val isKeyframe = header.get().toInt() == 1
        val frameID = header.int
        val index = header.short.toInt() and 0xFFFF
        val count = header.short.toInt() and 0xFFFF
        assertTrue(index < count)
        lastFrameID?.let { if (frameID - it <= 0) return null } // Older or the same: the Mac drops it.

        val frame = partial.getOrPut(frameID) { Partial(count, isKeyframe) }
        assertEquals(frame.chunkCount, count)
        assertEquals(frame.isKeyframe, isKeyframe)
        if (frame.chunks[index] == null) frame.received++
        frame.chunks[index] = datagram
        if (frame.received < count) return null

        lastFrameID = frameID
        partial.keys.removeAll { it - frameID <= 0 }
        val data = ByteArrayOutputStream()
        frame.chunks.forEach { data.write(it!!, VideoDatagram.HEADER_BYTE_COUNT, it.size - VideoDatagram.HEADER_BYTE_COUNT) }
        return Frame(frameID, isKeyframe, data.toByteArray())
    }
}

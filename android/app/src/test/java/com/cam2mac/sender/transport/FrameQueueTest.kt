package com.cam2mac.sender.transport

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FrameQueueTest {
    private fun frame(id: Int) = byteArrayOf(id.toByte())
    private fun FrameQueue.drain() = generateSequence { poll(0) }.map { it[0].toInt() }.toList()

    @Test
    fun dropsFramesWhileClosedAndDeltasBeforeTheFirstKeyframe() {
        val queue = FrameQueue(capacity = 4)
        queue.offer(frame(1), isKeyframe = true)
        assertNull(queue.poll(0))

        queue.open()
        assertFalse(queue.offer(frame(2), isKeyframe = false))
        assertFalse(queue.offer(frame(3), isKeyframe = true))
        assertFalse(queue.offer(frame(4), isKeyframe = false))
        assertEquals(listOf(3, 4), queue.drain())
    }

    @Test
    fun fullQueueDropsDeltasUntilTheNextKeyframeAndRequestsOne() {
        val queue = FrameQueue(capacity = 3)
        queue.open()
        queue.offer(frame(1), isKeyframe = true)
        queue.offer(frame(2), isKeyframe = false)
        queue.offer(frame(3), isKeyframe = false)

        // Overflow: this delta is dropped and a keyframe is requested once.
        assertTrue(queue.offer(frame(4), isKeyframe = false))
        // Later deltas would reference the dropped frame, so they are dropped too, even with room again.
        assertArrayEquals(frame(1), queue.poll(0))
        assertFalse(queue.offer(frame(5), isKeyframe = false))
        assertEquals(listOf(2, 3), queue.drain())
        assertFalse(queue.offer(frame(6), isKeyframe = false))
        assertNull(queue.poll(0))

        assertFalse(queue.offer(frame(7), isKeyframe = true))
        assertFalse(queue.offer(frame(8), isKeyframe = false))
        assertEquals(listOf(7, 8), queue.drain())
    }

    @Test
    fun keyframeIntoAFullQueueReplacesTheBacklog() {
        val queue = FrameQueue(capacity = 2)
        queue.open()
        queue.offer(frame(1), isKeyframe = true)
        queue.offer(frame(2), isKeyframe = false)
        assertFalse(queue.offer(frame(3), isKeyframe = true))
        assertEquals(listOf(3), queue.drain())
    }

    @Test
    fun closeAndReopenStartsWithAKeyframeAgain() {
        val queue = FrameQueue(capacity = 4)
        queue.open()
        queue.offer(frame(1), isKeyframe = true)
        queue.close()
        assertNull(queue.poll(0))
        queue.open()
        assertFalse(queue.offer(frame(2), isKeyframe = false))
        assertNull(queue.poll(0))
    }
}

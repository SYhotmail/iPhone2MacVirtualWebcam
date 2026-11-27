package com.cam2mac.sender.transport

import com.cam2mac.sender.transport.SendBacklog.Decision.DROP
import com.cam2mac.sender.transport.SendBacklog.Decision.DROP_AND_REQUEST_KEYFRAME
import com.cam2mac.sender.transport.SendBacklog.Decision.SEND
import org.junit.Assert.assertEquals
import org.junit.Test

class SendBacklogTest {
    private val backlog = SendBacklog(limitBytes = 100_000, initialBytesSent = 5_000)

    @Test
    fun dropsDeltasUntilTheFirstKeyframe() {
        // The caller already requested the first keyframe when streaming started.
        assertEquals(DROP, backlog.decide(1_000, isKeyframe = false, bytesSent = 5_000))
        assertEquals(SEND, backlog.decide(50_000, isKeyframe = true, bytesSent = 5_000))
        assertEquals(SEND, backlog.decide(1_000, isKeyframe = false, bytesSent = 5_000))
    }

    @Test
    fun sendsWhileTheQueueDrains() {
        var sent = 5_000L
        assertEquals(SEND, backlog.decide(60_000, isKeyframe = true, bytesSent = sent))
        repeat(100) {
            sent += 10_000
            assertEquals(SEND, backlog.decide(10_000, isKeyframe = false, bytesSent = sent))
        }
        assertEquals(60_000L, backlog.outstandingBytes)
    }

    @Test
    fun deltasMayQueueBehindAKeyframeLargerThanTheLimit() {
        assertEquals(SEND, backlog.decide(150_000, isKeyframe = true, bytesSent = 5_000))
        assertEquals(SEND, backlog.decide(10_000, isKeyframe = false, bytesSent = 5_000))
        assertEquals(SEND, backlog.decide(10_000, isKeyframe = false, bytesSent = 5_000))
    }

    @Test
    fun congestionDropsUntilDrainedThenRequestsOneKeyframe() {
        assertEquals(SEND, backlog.decide(50_000, isKeyframe = true, bytesSent = 5_000))
        repeat(11) { assertEquals(SEND, backlog.decide(10_000, isKeyframe = false, bytesSent = 5_000)) }
        // 160 kB queued, beyond limit + latest keyframe (150 kB): the link can't keep up.
        assertEquals(160_000L, backlog.outstandingBytes)
        assertEquals(DROP, backlog.decide(10_000, isKeyframe = false, bytesSent = 5_000))
        assertEquals(DROP, backlog.decide(10_000, isKeyframe = false, bytesSent = 25_000))
        // Still above the limit: a keyframe would only add latency.
        assertEquals(DROP, backlog.decide(50_000, isKeyframe = true, bytesSent = 45_000))
        // Drained below the limit: ask for a keyframe once, keep dropping deltas until it comes.
        assertEquals(DROP_AND_REQUEST_KEYFRAME, backlog.decide(10_000, isKeyframe = false, bytesSent = 105_000))
        assertEquals(DROP, backlog.decide(10_000, isKeyframe = false, bytesSent = 105_000))
        assertEquals(SEND, backlog.decide(50_000, isKeyframe = true, bytesSent = 105_000))
        assertEquals(SEND, backlog.decide(10_000, isKeyframe = false, bytesSent = 105_000))
    }

    @Test
    fun overheadInBytesSentDoesNotDriftBelowZero() {
        assertEquals(SEND, backlog.decide(10_000, isKeyframe = true, bytesSent = 5_000))
        // Packet headers, acks and retransmissions make bytesSent outrun what was handed over.
        assertEquals(SEND, backlog.decide(10_000, isKeyframe = false, bytesSent = 50_000))
        assertEquals(10_000L, backlog.outstandingBytes)
    }
}

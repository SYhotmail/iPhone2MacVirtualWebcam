package com.cam2mac.sender.transport

/**
 * Decides which video frames to hand to Kwik, whose send queue has no bound. It estimates the bytes still
 * queued from what was handed over and what Kwik reports as sent, and drops late deltas instead of letting
 * latency grow. Not thread-safe; the caller serializes calls.
 *
 * A connection starts out dropping deltas until its first keyframe (the Mac can't decode them without it),
 * with that keyframe already requested by the caller.
 */
internal class SendBacklog(
    /** Backlog above which deltas are dropped: about 290 ms of video at 2.8 Mbps. */
    private val limitBytes: Long = DEFAULT_LIMIT_BYTES,
    initialBytesSent: Long = 0,
) {
    enum class Decision { SEND, DROP, DROP_AND_REQUEST_KEYFRAME }

    private var outstanding = 0L
    private var lastBytesSent = initialBytesSent
    private var lastKeyframeBytes = 0L
    private var droppingUntilKeyframe = true
    private var keyframeRequested = true

    /** Bytes estimated to still wait in Kwik's queue. */
    val outstandingBytes: Long get() = outstanding

    /**
     * Whether to send a frame of [byteCount] bytes (datagram headers included), given Kwik's total
     * [bytesSent] so far. A frame that is sent is counted as handed over.
     */
    fun decide(byteCount: Int, isKeyframe: Boolean, bytesSent: Long): Decision {
        // Clamped at 0: bytesSent includes packet overhead and retransmissions, which would make it drift.
        outstanding = maxOf(0, outstanding - (bytesSent - lastBytesSent))
        lastBytesSent = bytesSent

        if (droppingUntilKeyframe) {
            // Still congested: even a keyframe would only add latency; wait for the queue to drain.
            if (outstanding > limitBytes) return Decision.DROP
            if (!isKeyframe) {
                if (keyframeRequested) return Decision.DROP
                keyframeRequested = true
                return Decision.DROP_AND_REQUEST_KEYFRAME
            }
            droppingUntilKeyframe = false
        } else if (!isKeyframe && outstanding > limitBytes + lastKeyframeBytes) {
            // The latest keyframe may legitimately sit in the queue (an IDR can exceed the limit alone), so
            // only a backlog beyond it means the link can't keep up. Drop until it drained, then ask for a
            // keyframe, since the dropped delta breaks the reference chain.
            droppingUntilKeyframe = true
            keyframeRequested = false
            return Decision.DROP
        }
        if (isKeyframe) lastKeyframeBytes = byteCount.toLong()
        outstanding += byteCount
        return Decision.SEND
    }

    companion object {
        const val DEFAULT_LIMIT_BYTES = 100_000L
    }
}

package com.cam2mac.sender.transport

/**
 * Bounded send queue between the encoder and the socket writer. When the queue is full, non-keyframes are
 * dropped until the next keyframe (they would reference a dropped frame), and the caller is asked for a keyframe.
 * Thread-safe.
 */
internal class FrameQueue(private val capacity: Int) {
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN") // wait/notify monitor
    private val lock = Object()
    private val frames = ArrayDeque<ByteArray>()
    private var accepting = false
    private var waitingForKeyframe = true

    /** Starts accepting frames for a new connection, beginning with a keyframe. */
    fun open() = synchronized(lock) {
        frames.clear()
        waitingForKeyframe = true
        accepting = true
    }

    /** Drops everything and stops accepting frames. */
    fun close() = synchronized(lock) {
        accepting = false
        frames.clear()
        lock.notifyAll()
    }

    /** Queues [frame] if it can be decoded; returns true when a keyframe is needed because the queue overflowed. */
    fun offer(frame: ByteArray, isKeyframe: Boolean): Boolean = synchronized(lock) {
        if (!accepting) return false
        if (isKeyframe) {
            waitingForKeyframe = false
            // Everything queued before a keyframe is obsolete once the queue backs up.
            if (frames.size >= capacity) frames.clear()
        } else if (waitingForKeyframe) {
            return false
        } else if (frames.size >= capacity) {
            waitingForKeyframe = true
            return true
        }
        frames.addLast(frame)
        lock.notifyAll()
        false
    }

    /** The oldest frame, waiting up to [timeoutMillis] for one; null if none arrived or [wake] was called. */
    fun poll(timeoutMillis: Long): ByteArray? = synchronized(lock) {
        // wait(0) would wait forever.
        if (frames.isEmpty() && timeoutMillis > 0) lock.wait(timeoutMillis)
        frames.removeFirstOrNull()
    }

    /** Returns a waiting [poll] early. */
    fun wake() = synchronized(lock) { lock.notifyAll() }
}

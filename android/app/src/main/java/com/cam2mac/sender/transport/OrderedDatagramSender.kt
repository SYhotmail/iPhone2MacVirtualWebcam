package com.cam2mac.sender.transport

import tech.kwik.core.common.EncryptionLevel
import tech.kwik.core.frame.DatagramFrame
import tech.kwik.core.frame.QuicFrame
import tech.kwik.core.impl.QuicConnectionImpl

/**
 * Sends QUIC datagrams in exactly the order they were queued. The Mac's `FrameReassembler` delivers frames
 * strictly in frame-ID order, so a datagram of frame N+1 arriving before the rest of frame N makes it drop N.
 *
 * Kwik 0.10.3 can't do this by itself:
 * - `sendDatagram` queues with priority (`SendRequestQueue.addPriorityRequest` → `Deque.addFirst`): LIFO.
 * - Even the FIFO queue (`addRequest` → `addLast`) is drained first-fit: `SendRequestQueue.next(maxSize)` takes the
 *   first request that fits the space left in the packet or congestion window, so a small datagram overtakes a
 *   queued full-size one.
 *
 * So the datagrams wait in our own queue, and Kwik holds at most one request for them, sized exactly like the
 * head datagram: when that one doesn't fit, nothing of ours does. When Kwik takes it, the supplier registers the
 * next one. Lost datagrams are never retransmitted. These are Kwik internals: recheck them when upgrading Kwik
 * (pinned in libs.versions.toml).
 */
internal class OrderedDatagramSender(private val connection: QuicConnectionImpl) {
    private val queue = ArrayDeque<DatagramFrame>()
    /** Whether Kwik holds a request for the head of [queue]. */
    private var requested = false

    /** Queues [datagram] behind everything queued before it. */
    fun send(datagram: ByteArray) {
        val register = synchronized(this) {
            queue.addLast(DatagramFrame(datagram))
            !requested.also { requested = true }
        }
        // From the caller's thread: wake Kwik's sender. While a request is pending, the sender keeps going.
        if (register) requestHead(flush = true)
    }

    /** Asks Kwik for room for the current head; only one such request exists at a time. */
    private fun requestHead(flush: Boolean) {
        val size = synchronized(this) { queue.first().frameLength }
        connection.send(::supplyHead, size, EncryptionLevel.App, { /* lost: never retransmit */ }, flush)
    }

    /** Called by Kwik's sender with at least the requested room. */
    private fun supplyHead(maximumSize: Int): QuicFrame? {
        val (head, more) = synchronized(this) {
            val head = queue.firstOrNull()?.takeIf { it.frameLength <= maximumSize }?.also { queue.removeFirst() }
            head to queue.isNotEmpty().also { requested = it }
        }
        // Registered from Kwik's sender thread, which may still use it for the packet being assembled.
        if (more) requestHead(flush = false)
        return head
    }
}

package com.cam2mac.sender.transport

import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Lets one NSD resolve run at a time. Before API 34, NsdManager allows a single in-flight resolve and cannot
 * cancel it, so a resolve that timed out keeps the slot until its own callback arrives; starting another one
 * earlier fails with FAILURE_ALREADY_ACTIVE.
 */
internal class ResolveSlot {
    private val permit = Semaphore(1)

    /**
     * Waits up to [timeoutMillis] for the previous resolve to finish. Returns the release function for this
     * resolve (safe to call more than once), or null if the slot stayed busy.
     */
    fun acquire(timeoutMillis: Long): (() -> Unit)? {
        if (!permit.tryAcquire(timeoutMillis, TimeUnit.MILLISECONDS)) return null
        val released = AtomicBoolean(false)
        return { if (released.compareAndSet(false, true)) permit.release() }
    }
}

package com.cam2mac.sender.transport

import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class ResolveSlotTest {
    @Test
    fun oneResolveAtATimeUntilItsCallbackReleases() {
        val slot = ResolveSlot()
        val first = slot.acquire(0)
        assertNotNull(first)
        // The first resolve timed out but its callback has not arrived: the slot stays busy.
        assertNull(slot.acquire(10))
        first!!()
        val second = slot.acquire(0)
        assertNotNull(second)
        second!!()
    }

    @Test
    fun releasingTwiceFreesOnlyOneSlot() {
        val slot = ResolveSlot()
        val first = slot.acquire(0)!!
        first()
        first() // Timeout path and callback both release.
        assertNotNull(slot.acquire(0))
        assertNull(slot.acquire(0))
    }

    @Test
    fun waitsForAReleaseFromAnotherThread() {
        val slot = ResolveSlot()
        val first = slot.acquire(0)!!
        Thread { Thread.sleep(50); first() }.start()
        assertNotNull(slot.acquire(2_000))
    }
}

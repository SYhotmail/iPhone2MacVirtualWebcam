package com.cam2mac.sender.transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ServiceNameMatcherTest {
    @Test
    fun matchesExactAndConflictRenamedNames() {
        assertTrue(ServiceNameMatcher.matches("Studio Mac", "Studio Mac"))
        assertTrue(ServiceNameMatcher.matches("Studio Mac", "Studio Mac (2)"))
        assertTrue(ServiceNameMatcher.matches("Studio Mac (2)", "Studio Mac"))
        assertTrue(ServiceNameMatcher.matches("Studio Mac (2)", "Studio Mac (3)"))
        assertTrue(ServiceNameMatcher.matches("Studio Mac", "Studio Mac-1"))
    }

    @Test
    fun rejectsUnrelatedNames() {
        assertFalse(ServiceNameMatcher.matches("Studio Mac", "Office Mac"))
        assertFalse(ServiceNameMatcher.matches("Studio Mac", "Studio"))
        assertFalse(ServiceNameMatcher.matches("Studio Mac", "My Studio Mac"))
        assertFalse(ServiceNameMatcher.matches("Studio Mac", "studio mac"))
    }

    @Test
    fun ranksExactThenRenamedThenPrefix() {
        val ranked = ServiceNameMatcher.ranked(
            "Studio Mac",
            listOf("Studio Mac Pro", "Office Mac", "Studio Mac (2)", "Studio Mac", "Studio Mac (2)"),
        )
        assertEquals(listOf("Studio Mac", "Studio Mac (2)", "Studio Mac Pro"), ranked)
    }
}

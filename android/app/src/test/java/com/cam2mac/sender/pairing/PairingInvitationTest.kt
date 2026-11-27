package com.cam2mac.sender.pairing

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PairingInvitationTest {
    private val fingerprintHex = "ab".repeat(32)
    private val tokenHex = "0123456789abcdef".repeat(2)

    private fun url(fp: String = fingerprintHex, t: String = tokenHex, n: String = "Studio%20Mac") =
        "cam2mac://pair?fp=$fp&t=$t&n=$n"

    @Test
    fun acceptsValidInvitation() {
        val invitation = PairingInvitation.parse(url())
        assertNotNull(invitation)
        invitation!!
        assertArrayEquals(ByteArray(32) { 0xab.toByte() }, invitation.fingerprint)
        assertEquals(16, invitation.token.size)
        assertEquals(0x01.toByte(), invitation.token[0])
        assertEquals("Studio Mac", invitation.serviceName)
    }

    @Test
    fun acceptsUppercaseHexAndLongerToken() {
        val invitation = PairingInvitation.parse(url(fp = fingerprintHex.uppercase(), t = "FF".repeat(32), n = "Mac"))
        assertNotNull(invitation)
        assertEquals(32, invitation!!.token.size)
    }

    @Test
    fun keepsPlusSignInServiceName() {
        assertEquals("A+B", PairingInvitation.parse(url(n = "A+B"))?.serviceName)
    }

    @Test
    fun firstOccurrenceOfAnItemWins() {
        assertEquals("First", PairingInvitation.parse(url(n = "First") + "&n=Second")?.serviceName)
    }

    @Test
    fun rejectsInvalidInvitations() {
        val rejected = listOf(
            "https://pair?fp=$fingerprintHex&t=$tokenHex&n=Mac",
            "cam2mac://other?fp=$fingerprintHex&t=$tokenHex&n=Mac",
            url(fp = "ab".repeat(31)),
            url(fp = "ab".repeat(33)),
            url(fp = "abc"),
            url(fp = "zz".repeat(32)),
            url(t = "ab".repeat(15)),
            url(t = "ab".repeat(15) + "a"),
            url(n = ""),
            url(n = "%zz"),
            "cam2mac://pair?fp=$fingerprintHex&t=$tokenHex",
            "cam2mac://pair?t=$tokenHex&n=Mac",
            "cam2mac://pair",
            "not a url",
            "",
        )
        for (text in rejected) {
            assertNull("Accepted: $text", PairingInvitation.parse(text))
        }
    }
}

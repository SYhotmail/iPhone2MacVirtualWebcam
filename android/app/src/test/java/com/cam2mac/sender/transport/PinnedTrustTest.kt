package com.cam2mac.sender.transport

import org.junit.Assert.assertThrows
import org.junit.Test
import java.security.cert.CertificateException

class PinnedTrustTest {
    private val mac = TestIdentity()

    @Test
    fun acceptsPinnedCertificate() {
        PinnedTrust(mac.fingerprint).checkServerTrusted(arrayOf(mac.certificate), "ECDHE_ECDSA")
    }

    @Test
    fun rejectsOtherCertificate() {
        val other = TestIdentity()
        assertThrows(FingerprintMismatchException::class.java) {
            PinnedTrust(mac.fingerprint).checkServerTrusted(arrayOf(other.certificate), "ECDHE_ECDSA")
        }
    }

    @Test
    fun rejectsEmptyChainAndClients() {
        val trust = PinnedTrust(mac.fingerprint)
        assertThrows(CertificateException::class.java) { trust.checkServerTrusted(emptyArray(), "ECDHE_ECDSA") }
        assertThrows(CertificateException::class.java) { trust.checkClientTrusted(arrayOf(mac.certificate), "ECDHE_ECDSA") }
    }
}

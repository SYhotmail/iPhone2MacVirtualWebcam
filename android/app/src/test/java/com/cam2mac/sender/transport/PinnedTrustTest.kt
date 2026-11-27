package com.cam2mac.sender.transport

import org.junit.Assert.assertThrows
import org.junit.Test
import java.security.cert.CertificateException

class PinnedTrustTest {
    private val mac = TestIdentity()

    @Test
    fun acceptsPinnedCertificate() {
        PinnedTrust(mac.fingerprint).check(listOf(mac.certificate))
    }

    @Test
    fun rejectsOtherCertificate() {
        assertThrows(FingerprintMismatchException::class.java) {
            PinnedTrust(mac.fingerprint).check(listOf(TestIdentity().certificate))
        }
    }

    @Test
    fun rejectsMissingCertificate() {
        val trust = PinnedTrust(mac.fingerprint)
        assertThrows(CertificateException::class.java) { trust.check(emptyList()) }
        assertThrows(CertificateException::class.java) { trust.check(null) }
    }
}

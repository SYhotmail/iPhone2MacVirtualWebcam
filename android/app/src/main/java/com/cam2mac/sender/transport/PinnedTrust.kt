package com.cam2mac.sender.transport

import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate

/** The server certificate is not the one the QR code pinned. */
class FingerprintMismatchException : CertificateException("The receiver's certificate does not match the paired Mac")

/**
 * Accepts only the server whose leaf certificate's SHA-256 equals [fingerprint], like
 * `TransportTLSParameters.leafCertificateMatches` on Apple platforms. The Mac's certificate is self-signed and
 * found through Bonjour, so there is no chain or hostname to check.
 */
class PinnedTrust(private val fingerprint: ByteArray) {
    /** Throws unless the leaf of [chain] is the pinned certificate. */
    fun check(chain: List<X509Certificate>?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("The receiver sent no certificate")
        val digest = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
        if (!MessageDigest.isEqual(digest, fingerprint)) throw FingerprintMismatchException()
    }
}

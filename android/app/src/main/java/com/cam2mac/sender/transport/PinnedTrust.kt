package com.cam2mac.sender.transport

import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedTrustManager

/** The server certificate is not the one the QR code pinned. */
class FingerprintMismatchException : CertificateException("The receiver's certificate does not match the paired Mac")

/**
 * Accepts only the server whose leaf certificate's SHA-256 equals [fingerprint], like
 * `TransportTLSParameters.leafCertificateMatches` on Apple platforms. The Mac's certificate is self-signed and
 * found through Bonjour, so there is no chain or hostname to check.
 */
class PinnedTrust(private val fingerprint: ByteArray) : X509ExtendedTrustManager() {
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("The receiver sent no certificate")
        val digest = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
        if (!MessageDigest.isEqual(digest, fingerprint)) throw FingerprintMismatchException()
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) =
        checkServerTrusted(chain, authType)

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) =
        checkServerTrusted(chain, authType)

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
        throw CertificateException("Client certificates are not accepted")

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) =
        checkClientTrusted(chain, authType)

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) =
        checkClientTrusted(chain, authType)

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    fun sslContext(): SSLContext = SSLContext.getInstance("TLS").apply {
        init(null, arrayOf(this@PinnedTrust), SecureRandom())
    }
}

package com.cam2mac.sender.transport

import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.math.BigInteger
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext

/** A self-signed P-256 identity like the one each Mac creates (`SelfSignedCertificate`). */
class TestIdentity {
    val keyPair: KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
        .generateKeyPair()

    val certificate: X509Certificate = run {
        val name = X500Name("CN=Cam2Mac Test")
        val now = System.currentTimeMillis()
        val holder = JcaX509v3CertificateBuilder(
            name, BigInteger.valueOf(now), Date(now - 60_000), Date(now + 86_400_000), name, keyPair.public
        ).build(JcaContentSignerBuilder("SHA256withECDSA").build(keyPair.private))
        JcaX509CertificateConverter().getCertificate(holder)
    }

    val fingerprint: ByteArray = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)

    fun serverContext(): SSLContext {
        val password = CharArray(0)
        val keyStore = KeyStore.getInstance("PKCS12").apply {
            load(null)
            setKeyEntry("mac", keyPair.private, password, arrayOf(certificate))
        }
        val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
            .apply { init(keyStore, password) }.keyManagers
        return SSLContext.getInstance("TLS").apply { init(keyManagers, null, null) }
    }
}

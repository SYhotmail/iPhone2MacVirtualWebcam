package com.cam2mac.sender.pairing

import java.net.URI
import java.net.URISyntaxException

/**
 * Contents of the QR code the Mac shows for pairing:
 * `cam2mac://pair?fp=<hex SHA-256 of the Mac certificate>&t=<hex one-time token>&n=<Bonjour service name>`.
 *
 * Mirrors `PairingInvitation.init?(url:)` in `Transport/Sources/Transport/Pairing.swift`.
 */
class PairingInvitation(
    /** SHA-256 of the Mac's DER certificate. */
    val fingerprint: ByteArray,
    /** One-time pairing secret. */
    val token: ByteArray,
    /** Bonjour service name the Mac advertises. */
    val serviceName: String,
) {
    companion object {
        const val SCHEME = "cam2mac"
        private const val HOST = "pair"
        private const val FINGERPRINT_BYTES = 32
        private const val MINIMUM_TOKEN_BYTES = 16

        fun parse(text: String): PairingInvitation? {
            val uri = try {
                URI(text)
            } catch (_: URISyntaxException) {
                return null
            }
            if (uri.scheme != SCHEME || uri.host != HOST) return null
            val items = queryItems(uri.rawQuery ?: return null) ?: return null
            // Like URLComponents.queryItems.first(where:), the first occurrence of a name wins.
            fun value(name: String) = items.firstOrNull { it.first == name }?.second

            val fingerprint = value("fp")?.let(Hex::decode) ?: return null
            if (fingerprint.size != FINGERPRINT_BYTES) return null
            val token = value("t")?.let(Hex::decode) ?: return null
            if (token.size < MINIMUM_TOKEN_BYTES) return null
            val serviceName = value("n")
            if (serviceName.isNullOrEmpty()) return null
            return PairingInvitation(fingerprint, token, serviceName)
        }

        /** Percent-decodes query items the way URLComponents does: `+` stays a plus sign. */
        private fun queryItems(rawQuery: String): List<Pair<String, String>>? =
            rawQuery.split('&').map { item ->
                val name = item.substringBefore('=')
                val value = item.substringAfter('=', missingDelimiterValue = "")
                val decodedName = percentDecode(name) ?: return null
                val decodedValue = percentDecode(value) ?: return null
                decodedName to decodedValue
            }

        private fun percentDecode(text: String): String? {
            val bytes = java.io.ByteArrayOutputStream(text.length)
            var index = 0
            while (index < text.length) {
                val char = text[index]
                if (char == '%') {
                    if (index + 3 > text.length) return null
                    val byte = Hex.decode(text.substring(index + 1, index + 3)) ?: return null
                    bytes.write(byte)
                    index += 3
                } else {
                    bytes.write(char.toString().toByteArray(Charsets.UTF_8))
                    index += 1
                }
            }
            return bytes.toByteArray().toString(Charsets.UTF_8)
        }
    }
}

internal object Hex {
    fun decode(text: String): ByteArray? {
        if (text.length % 2 != 0) return null
        val bytes = ByteArray(text.length / 2)
        for (i in bytes.indices) {
            val high = Character.digit(text[2 * i], 16)
            val low = Character.digit(text[2 * i + 1], 16)
            if (high < 0 || low < 0) return null
            bytes[i] = ((high shl 4) or low).toByte()
        }
        return bytes
    }

    fun encode(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}

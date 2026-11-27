package com.cam2mac.sender.pairing

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.Base64
import java.util.UUID

/**
 * First packet a client sends on every connection. The JSON matches what Swift's `JSONEncoder` produces for
 * `PairingHello` in `Transport/Sources/Transport/Pairing.swift`: `Data` is base64, `UUID` is an uppercase string,
 * and absent optionals are omitted.
 */
@Serializable
class PairingHello private constructor(
    @SerialName("v") val version: Int,
    @SerialName("type") val kind: Kind,
    val clientID: String,
    val secret: String,
    val token: String? = null,
    @SerialName("name") val deviceName: String? = null,
) {
    @Serializable
    enum class Kind {
        /** First connection: proves the client scanned the Mac's QR code and registers its secret. */
        @SerialName("pair") PAIR,
        /** Later connections: authenticates with the registered secret. */
        @SerialName("hello") HELLO,
    }

    fun encode(): ByteArray = json.encodeToString(serializer(), this).toByteArray(Charsets.UTF_8)

    companion object {
        const val CURRENT_VERSION = 3
        /** The Mac rejects larger hellos (`PairingHello.maximumEncodedSize`); keep the free-form name well below that. */
        private const val MAXIMUM_DEVICE_NAME_LENGTH = 200

        fun pair(token: ByteArray, clientID: UUID, secret: ByteArray, deviceName: String) = PairingHello(
            version = CURRENT_VERSION,
            kind = Kind.PAIR,
            clientID = clientID.uppercase(),
            secret = base64(secret),
            token = base64(token),
            deviceName = deviceName.take(MAXIMUM_DEVICE_NAME_LENGTH),
        )

        fun hello(clientID: UUID, secret: ByteArray) = PairingHello(
            version = CURRENT_VERSION,
            kind = Kind.HELLO,
            clientID = clientID.uppercase(),
            secret = base64(secret),
        )

        private fun UUID.uppercase() = toString().uppercase()
        private fun base64(bytes: ByteArray) = Base64.getEncoder().encodeToString(bytes)
    }
}

/** The receiver's answer to a `PairingHello`. */
@Serializable
data class PairingReply(val ok: Boolean, val reason: String? = null) {
    companion object {
        fun decode(bytes: ByteArray): PairingReply = json.decodeFromString(serializer(), bytes.toString(Charsets.UTF_8))
    }
}

private val json = Json {
    explicitNulls = false
    ignoreUnknownKeys = true
}

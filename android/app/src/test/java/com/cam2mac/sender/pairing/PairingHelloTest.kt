package com.cam2mac.sender.pairing

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class PairingHelloTest {
    private val clientID = UUID.fromString("0b9a1c2d-3e4f-4a5b-8c6d-7e8f9a0b1c2d")
    private val secret = ByteArray(32) { it.toByte() }
    private val token = ByteArray(16) { (0xf0 + it).toByte() }

    private fun decode(hello: PairingHello) =
        Json.parseToJsonElement(hello.encode().toString(Charsets.UTF_8)).jsonObject

    @Test
    fun pairEncodesLikeSwiftJSONEncoder() {
        val json = decode(PairingHello.pair(token, clientID, secret, "Pixel 9"))
        assertEquals(setOf("v", "type", "clientID", "secret", "token", "name"), json.keys)
        assertEquals(JsonPrimitive(3), json["v"])
        assertEquals(JsonPrimitive("pair"), json["type"])
        assertEquals(JsonPrimitive("0B9A1C2D-3E4F-4A5B-8C6D-7E8F9A0B1C2D"), json["clientID"])
        assertEquals(JsonPrimitive("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="), json["secret"])
        assertEquals(JsonPrimitive("8PHy8/T19vf4+fr7/P3+/w=="), json["token"])
        assertEquals(JsonPrimitive("Pixel 9"), json["name"])
    }

    @Test
    fun helloOmitsTokenAndName() {
        val text = PairingHello.hello(clientID, secret).encode().toString(Charsets.UTF_8)
        val json = Json.parseToJsonElement(text).jsonObject
        assertEquals(setOf("v", "type", "clientID", "secret"), json.keys)
        assertEquals(JsonPrimitive("hello"), json["type"])
        assertFalse(text.contains("null"))
    }

    @Test
    fun longDeviceNameStaysBelowTheMacLimit() {
        val hello = PairingHello.pair(token, clientID, secret, "x".repeat(10_000))
        assertTrue(hello.encode().size < 4096)
    }

    @Test
    fun decodesReplies() {
        assertEquals(PairingReply(ok = true), PairingReply.decode("""{"ok":true}""".toByteArray()))
        assertEquals(
            PairingReply(ok = false, reason = "Unknown client"),
            PairingReply.decode("""{"ok":false,"reason":"Unknown client"}""".toByteArray()),
        )
    }
}

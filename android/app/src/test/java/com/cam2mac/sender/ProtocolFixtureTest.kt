package com.cam2mac.sender

import com.cam2mac.sender.pairing.Hex
import com.cam2mac.sender.pairing.PairingHello
import com.cam2mac.sender.pairing.PairingInvitation
import com.cam2mac.sender.pairing.PairingReply
import com.cam2mac.sender.transport.FramePacket
import com.cam2mac.sender.transport.VideoDatagram
import com.cam2mac.sender.video.AccessUnitAssembler
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

/** Checks the Kotlin protocol code against `ProtocolFixtures/`, which the Swift tests read too. */
class ProtocolFixtureTest {
    private fun fixture(name: String): JsonObject {
        val dir = System.getProperty("protocolFixtures") ?: error("protocolFixtures system property is not set")
        return Json.parseToJsonElement(File(dir, name).readText()).jsonObject
    }

    private fun JsonObject.string(key: String) = getValue(key).jsonPrimitive.content
    private fun JsonObject.optionalString(key: String) = (get(key) as? JsonPrimitive)?.contentOrNull
    private fun JsonObject.hex(key: String) = Hex.decode(string(key)) ?: error("$key is not hex")
    private fun JsonElement.cases() = jsonObject.getValue("cases").jsonArray.map { it.jsonObject }.also { assertTrue(it.isNotEmpty()) }

    @Test
    fun helloEncodesToFixtureJSON() {
        for (case in fixture("pairing-hello.json").cases()) {
            val clientID = UUID.fromString(case.string("clientID"))
            val hello = when (case.string("kind")) {
                "pair" -> PairingHello.pair(case.hex("tokenHex"), clientID, case.hex("secretHex"), case.string("deviceName"))
                else -> PairingHello.hello(clientID, case.hex("secretHex"))
            }
            val encoded = Json.parseToJsonElement(hello.encode().toString(Charsets.UTF_8))
            assertEquals(case.string("name"), case.getValue("json"), encoded)
        }
    }

    @Test
    fun replyDecodesFixtures() {
        for (case in fixture("pairing-reply.json").cases()) {
            val expected = PairingReply(
                ok = case.getValue("ok").jsonPrimitive.booleanOrNull!!,
                reason = case.optionalString("reason"),
            )
            assertEquals(case.string("json"), expected, PairingReply.decode(case.string("json").toByteArray()))
        }
    }

    @Test
    fun invitationMatchesFixtures() {
        val fixture = fixture("pairing-invitation.json")
        val valid = fixture.getValue("valid").jsonArray.map { it.jsonObject }
        val invalid = fixture.getValue("invalid").jsonArray.map { it.jsonObject }
        assertTrue(valid.isNotEmpty() && invalid.isNotEmpty())
        for (case in valid) {
            val url = case.string("url")
            val parsed = checkNotNull(PairingInvitation.parse(url)) { "should parse: $url" }
            assertArrayEquals(url, case.hex("fingerprintHex"), parsed.fingerprint)
            assertArrayEquals(url, case.hex("tokenHex"), parsed.token)
            assertEquals(url, case.string("serviceName"), parsed.serviceName)
        }
        for (case in invalid) {
            assertNull("${case.string("why")}: ${case.string("url")}", PairingInvitation.parse(case.string("url")))
        }
    }

    @Test
    fun framePacketMatchesFixtures() {
        for (case in fixture("frame-packet.json").cases()) {
            val payload = case.hex("payloadHex")
            val packet = case.hex("packetHex")
            val written = ByteArrayOutputStream().also { FramePacket.write(it, payload) }.toByteArray()
            assertArrayEquals(case.string("name"), packet, written)
            assertArrayEquals(case.string("name"), payload, FramePacket.read(ByteArrayInputStream(packet), Int.MAX_VALUE))
        }
    }

    @Test
    fun startCodesNormalizeToFixture() {
        for (case in fixture("annexb-start-codes.json").cases()) {
            val normalized = AccessUnitAssembler.normalizeStartCodes(case.hex("inputHex"))
            assertArrayEquals(case.string("name"), case.hex("normalizedHex"), normalized)
            // Normalizing what the Mac receives must be a no-op.
            assertArrayEquals(case.string("name"), normalized, AccessUnitAssembler.normalizeStartCodes(normalized))
        }
    }

    @Test
    fun videoDatagramsMatchFixtures() {
        for (case in fixture("video-datagram.json").cases()) {
            val datagrams = VideoDatagram.chunks(
                frame = case.hex("frameHex"),
                frameID = case.getValue("frameID").jsonPrimitive.long.toInt(), // u32 as Int bits
                isKeyframe = case.getValue("isKeyframe").jsonPrimitive.booleanOrNull!!,
                maximumDatagramSize = case.getValue("maximumDatagramSize").jsonPrimitive.content.toInt(),
            )
            val expected = case.getValue("datagramsHex").jsonArray.map { it.jsonPrimitive.content }
            assertEquals(case.string("name"), expected, datagrams.map(Hex::encode))
        }
    }
}

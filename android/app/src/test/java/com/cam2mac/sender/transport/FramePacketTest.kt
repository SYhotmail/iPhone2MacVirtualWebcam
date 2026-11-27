package com.cam2mac.sender.transport

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream

class FramePacketTest {
    /** Returns at most one byte per read, like a socket delivering a packet in pieces. */
    private class TrickleInputStream(bytes: ByteArray) : InputStream() {
        private val source = ByteArrayInputStream(bytes)
        override fun read(): Int = source.read()
        override fun read(b: ByteArray, off: Int, len: Int): Int = if (len == 0) 0 else source.read(b, off, 1)
    }

    @Test
    fun roundTripsPacketsAcrossPartialReads() {
        val payloads = listOf(ByteArray(0), byteArrayOf(0x01), ByteArray(70_000) { it.toByte() })
        val output = ByteArrayOutputStream()
        payloads.forEach { FramePacket.write(output, it) }

        val input = TrickleInputStream(output.toByteArray())
        payloads.forEach { assertArrayEquals(it, FramePacket.read(input, Int.MAX_VALUE)) }
    }

    @Test
    fun headerIsBigEndianLength() {
        val output = ByteArrayOutputStream()
        FramePacket.write(output, ByteArray(0x010203))
        assertArrayEquals(byteArrayOf(0x00, 0x01, 0x02, 0x03), output.toByteArray().copyOf(4))
    }

    @Test
    fun throwsWhenStreamEndsMidPacket() {
        val output = ByteArrayOutputStream()
        FramePacket.write(output, ByteArray(10))
        val truncated = output.toByteArray().copyOf(8)
        assertThrows(EOFException::class.java) { FramePacket.read(TrickleInputStream(truncated), 100) }
    }

    @Test
    fun rejectsOversizedPackets() {
        val output = ByteArrayOutputStream()
        FramePacket.write(output, ByteArray(101))
        assertThrows(IOException::class.java) { FramePacket.read(ByteArrayInputStream(output.toByteArray()), 100) }
    }
}

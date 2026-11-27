package com.cam2mac.sender.transport

import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * Stream framing shared with the Mac (`FramePacket.swift`): a 4-byte big-endian payload length, then the payload.
 */
object FramePacket {
    const val HEADER_BYTES = 4

    fun write(output: OutputStream, payload: ByteArray) {
        val size = payload.size
        output.write(byteArrayOf((size ushr 24).toByte(), (size ushr 16).toByte(), (size ushr 8).toByte(), size.toByte()))
        output.write(payload)
    }

    /** Reads one packet; `readFully` keeps reading across partial reads until the header and payload are complete. */
    fun read(input: InputStream, maximumPayloadSize: Int): ByteArray {
        val data = DataInputStream(input)
        val size = data.readInt().toLong() and 0xffff_ffffL
        if (size > maximumPayloadSize) {
            throw IOException("Packet of $size bytes exceeds limit $maximumPayloadSize")
        }
        return ByteArray(size.toInt()).also(data::readFully)
    }
}

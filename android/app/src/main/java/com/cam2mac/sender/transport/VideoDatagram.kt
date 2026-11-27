package com.cam2mac.sender.transport

/**
 * Wire format for video frames sent as QUIC datagrams, like `VideoDatagram` in the Swift Transport package.
 *
 * A frame is split into chunks that each fit one datagram. Every chunk starts with a 10-byte big-endian header:
 * `version: u8 | flags: u8 (bit 0 = keyframe) | frameID: u32 | chunkIndex: u16 | chunkCount: u16`.
 * The Mac's `FrameReassembler` rebuilds whole frames and drops incomplete ones.
 */
object VideoDatagram {
    const val VERSION: Byte = 1
    const val HEADER_BYTE_COUNT = 10
    /** Upper bound on one datagram; fits any IPv6 path. */
    const val MAXIMUM_DATAGRAM_SIZE = 1200
    private const val KEYFRAME_FLAG: Byte = 1
    private const val MAXIMUM_CHUNK_COUNT = 0xFFFF

    /**
     * Splits [frame] into datagrams no larger than [maximumDatagramSize]. [frameID] is used as an unsigned 32-bit
     * value. Returns an empty list when the frame is empty, a datagram can't hold any payload, or the frame would
     * need more than 65535 chunks.
     */
    fun chunks(frame: ByteArray, frameID: Int, isKeyframe: Boolean, maximumDatagramSize: Int): List<ByteArray> {
        val payloadCapacity = maximumDatagramSize - HEADER_BYTE_COUNT
        if (frame.isEmpty() || payloadCapacity <= 0) return emptyList()
        val chunkCount = (frame.size + payloadCapacity - 1) / payloadCapacity
        if (chunkCount > MAXIMUM_CHUNK_COUNT) return emptyList()

        return List(chunkCount) { index ->
            val start = index * payloadCapacity
            val end = minOf(start + payloadCapacity, frame.size)
            ByteArray(HEADER_BYTE_COUNT + end - start).also { datagram ->
                datagram[0] = VERSION
                datagram[1] = if (isKeyframe) KEYFRAME_FLAG else 0
                datagram[2] = (frameID ushr 24).toByte()
                datagram[3] = (frameID ushr 16).toByte()
                datagram[4] = (frameID ushr 8).toByte()
                datagram[5] = frameID.toByte()
                datagram[6] = (index ushr 8).toByte()
                datagram[7] = index.toByte()
                datagram[8] = (chunkCount ushr 8).toByte()
                datagram[9] = chunkCount.toByte()
                frame.copyInto(datagram, HEADER_BYTE_COUNT, start, end)
            }
        }
    }
}

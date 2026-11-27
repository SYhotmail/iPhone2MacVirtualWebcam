package com.cam2mac.sender.video

import android.media.MediaCodec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AccessUnitAssemblerTest {
    private val startCode = byteArrayOf(0, 0, 0, 1)
    private val parameterSets = startCode + byteArrayOf(0x40, 0x01) + startCode + byteArrayOf(0x42, 0x01) +
        startCode + byteArrayOf(0x44, 0x01)
    private val idr = startCode + byteArrayOf(0x26, 0x01, 0x55)
    private val delta = startCode + byteArrayOf(0x02, 0x01, 0x66)

    @Test
    fun prependsParameterSetsToEveryKeyframe() {
        val assembler = AccessUnitAssembler()
        assertNull(assembler.process(parameterSets, MediaCodec.BUFFER_FLAG_CODEC_CONFIG))

        repeat(2) {
            val keyframe = assembler.process(idr, MediaCodec.BUFFER_FLAG_KEY_FRAME)!!
            assertTrue(keyframe.isKeyframe)
            assertArrayEquals(parameterSets + idr, keyframe.data)

            val frame = assembler.process(delta, 0)!!
            assertFalse(frame.isKeyframe)
            assertArrayEquals(delta, frame.data)
        }
    }

    @Test
    fun usesLatestParameterSets() {
        val assembler = AccessUnitAssembler()
        assembler.process(parameterSets, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
        val updated = startCode + byteArrayOf(0x40, 0x02)
        assembler.process(updated, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
        assertArrayEquals(updated + idr, assembler.process(idr, MediaCodec.BUFFER_FLAG_KEY_FRAME)!!.data)
    }

    @Test
    fun skipsEmptyBuffers() {
        assertNull(AccessUnitAssembler().process(ByteArray(0), MediaCodec.BUFFER_FLAG_END_OF_STREAM))
    }

    @Test
    fun widensThreeByteStartCodesInParameterSetsAndFrames() {
        val short = byteArrayOf(0, 0, 1)
        val assembler = AccessUnitAssembler()
        assembler.process(short + byteArrayOf(0x40, 0x01) + short + byteArrayOf(0x42, 0x01), MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
        val keyframe = assembler.process(short + byteArrayOf(0x26, 0x01), MediaCodec.BUFFER_FLAG_KEY_FRAME)!!
        assertArrayEquals(
            startCode + byteArrayOf(0x40, 0x01) + startCode + byteArrayOf(0x42, 0x01) + startCode + byteArrayOf(0x26, 0x01),
            keyframe.data,
        )
        assertArrayEquals(startCode + byteArrayOf(0x02), assembler.process(short + byteArrayOf(0x02), 0)!!.data)
    }

    @Test
    fun keepsFourByteStartCodesAndPayloadAsIs() {
        assertArrayEquals(parameterSets, AccessUnitAssembler.normalizeStartCodes(parameterSets))
        // Mixed: a 4-byte code followed by a 3-byte one.
        val mixed = startCode + byteArrayOf(0x40) + byteArrayOf(0, 0, 1, 0x42)
        assertArrayEquals(startCode + byteArrayOf(0x40) + startCode + byteArrayOf(0x42), AccessUnitAssembler.normalizeStartCodes(mixed))
    }

    @Test
    fun seedsParameterSetsFromCsdWhenNoConfigBufferArrives() {
        val assembler = AccessUnitAssembler()
        assembler.seedParameterSets(byteArrayOf(0, 0, 1, 0x40, 0x01))
        assertArrayEquals(startCode + byteArrayOf(0x40, 0x01) + idr, assembler.process(idr, MediaCodec.BUFFER_FLAG_KEY_FRAME)!!.data)

        // A CODEC_CONFIG buffer wins, and a later csd-0 does not replace it.
        assembler.process(parameterSets, MediaCodec.BUFFER_FLAG_CODEC_CONFIG)
        assembler.seedParameterSets(byteArrayOf(0, 0, 0, 1, 0x40, 0x09))
        assertArrayEquals(parameterSets + idr, assembler.process(idr, MediaCodec.BUFFER_FLAG_KEY_FRAME)!!.data)
    }
}

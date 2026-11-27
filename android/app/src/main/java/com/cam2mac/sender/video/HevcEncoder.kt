package com.cam2mac.sender.video

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface

/**
 * Turns MediaCodec output buffers into packets the Mac decodes on its own: Annex-B access units where every
 * keyframe starts with the VPS/SPS/PPS that MediaCodec emits as `BUFFER_FLAG_CODEC_CONFIG` (or in `csd-0`).
 * All start codes are 4 bytes, the only form the Mac's `VideoDecoder.splitAnnexBNALUnits` recognises.
 */
class AccessUnitAssembler {
    private var parameterSets: ByteArray? = null

    /** Returns the packet to send, or null for codec config (cached) and empty buffers. */
    fun process(data: ByteArray, flags: Int): EncodedFrame? {
        if (flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
            parameterSets = normalizeStartCodes(data)
            return null
        }
        if (data.isEmpty()) return null
        val isKeyframe = flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        val frame = normalizeStartCodes(data)
        val parameterSets = parameterSets
        return if (isKeyframe && parameterSets != null) {
            EncodedFrame(parameterSets + frame, isKeyframe = true)
        } else {
            EncodedFrame(frame, isKeyframe)
        }
    }

    /** Uses `csd-0` from the output format when the encoder emitted no `BUFFER_FLAG_CODEC_CONFIG` buffer. */
    fun seedParameterSets(csd: ByteArray) {
        if (parameterSets == null && csd.isNotEmpty()) parameterSets = normalizeStartCodes(csd)
    }

    companion object {
        /** Widens 3-byte start codes (`00 00 01`) to 4 bytes (`00 00 00 01`); 4-byte ones stay as they are. */
        fun normalizeStartCodes(data: ByteArray): ByteArray {
            fun isShortStartCode(i: Int) = i + 2 < data.size && data[i] == ZERO && data[i + 1] == ZERO &&
                data[i + 2] == ONE && (i == 0 || data[i - 1] != ZERO)

            if (data.indices.none(::isShortStartCode)) return data
            val out = java.io.ByteArrayOutputStream(data.size + 16)
            for (i in data.indices) {
                if (isShortStartCode(i)) out.write(0)
                out.write(data[i].toInt())
            }
            return out.toByteArray()
        }

        private const val ZERO: Byte = 0
        private const val ONE: Byte = 1
    }
}

class EncodedFrame(val data: ByteArray, val isKeyframe: Boolean)

/** This phone cannot encode HEVC, which the Mac receiver requires. */
class HevcUnsupportedException : IllegalStateException("This phone has no HEVC (H.265) video encoder, which Cam2Mac needs.")

/**
 * Hardware HEVC encoder fed through an input [Surface], configured like the iPhone's `VideoEncoder`:
 * portrait 720x1280 at 30 fps, a keyframe every second, no B-frames, real-time priority.
 */
class HevcEncoder(
    private val onFrame: (EncodedFrame) -> Unit,
    private val onError: (Exception) -> Unit,
) {
    val width = 720
    val height = 1280

    /** Runs the codec callbacks and [release], so a callback never touches a stopped codec. */
    private val thread = HandlerThread("HevcEncoder").apply { start() }
    private val handler = Handler(thread.looper)
    private var released = false
    private val assembler = AccessUnitAssembler()
    private val codec: MediaCodec
    val inputSurface: Surface

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_HEVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) setInteger(MediaFormat.KEY_LATENCY, 1)
        }
        val name = MediaCodecList(MediaCodecList.REGULAR_CODECS).findEncoderForFormat(format)
            ?: run {
                thread.quitSafely()
                throw HevcUnsupportedException()
            }
        codec = MediaCodec.createByCodecName(name)
        try {
            codec.setCallback(Callback(), handler)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = codec.createInputSurface()
            codec.start()
        } catch (error: Exception) {
            codec.release()
            thread.quitSafely()
            throw error
        }
    }

    fun requestKeyframe() {
        runCatching {
            codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        }
    }

    /** Stops the codec on its callback thread and waits for that. */
    fun release() {
        val done = java.util.concurrent.CountDownLatch(1)
        handler.post {
            released = true
            runCatching { codec.stop() }
            codec.release()
            inputSurface.release()
            done.countDown()
        }
        done.await()
        thread.quitSafely()
    }

    private inner class Callback : MediaCodec.Callback() {
        override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

        override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (released) return
            val data = try {
                val buffer = codec.getOutputBuffer(index) ?: return
                ByteArray(info.size).also {
                    buffer.position(info.offset)
                    buffer.get(it, 0, info.size)
                    codec.releaseOutputBuffer(index, false)
                }
            } catch (_: IllegalStateException) {
                return
            }
            assembler.process(data, info.flags)?.let(onFrame)
        }

        override fun onError(codec: MediaCodec, error: MediaCodec.CodecException) {
            if (!released) onError(error)
        }

        override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) {
            val csd = format.getByteBuffer("csd-0") ?: return
            assembler.seedParameterSets(ByteArray(csd.remaining()).also { csd.duplicate().get(it) })
        }
    }

    private companion object {
        /** `VideoEncoder.targetBitRate` for 720x1280 on the iPhone. */
        const val BIT_RATE = 2_800_000
        const val FRAME_RATE = 30
    }
}

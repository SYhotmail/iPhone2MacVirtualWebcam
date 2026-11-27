package com.cam2mac.sender.video

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Draws camera frames from a [SurfaceTexture] into the encoder's input surface and an on-screen preview.
 * Each frame is rotated upright for portrait, horizontally mirrored like the iPhone sender, and center-cropped to
 * each target's aspect ratio. All GL work runs on one thread.
 */
class GlFrameRenderer {
    private class Target(val surface: EGLSurface, val width: Int, val height: Int)

    private val thread = HandlerThread("GlFrameRenderer").apply { start() }
    private val handler = Handler(thread.looper)

    /** Runs work on the GL thread. */
    val executor = Executor { handler.post(it) }

    private lateinit var display: EGLDisplay
    private lateinit var context: EGLContext
    private lateinit var config: EGLConfig
    private lateinit var placeholderSurface: EGLSurface
    private var program = 0
    private var textureId = 0

    /** Camera frames go here; report their size with [setCameraInput]. */
    lateinit var cameraTexture: SurfaceTexture
        private set

    private var cameraWidth = 0
    private var cameraHeight = 0
    private var rotationDegrees = 0
    private var encoder: Target? = null
    private var preview: Target? = null
    private val stMatrix = FloatArray(16)
    private val texMatrix = FloatArray(16)
    private val orientMatrix = FloatArray(16)

    init {
        runBlocking { setUp() }
    }

    /** The camera buffer size. */
    fun setCameraInput(width: Int, height: Int) {
        runOnGlThread {
            cameraWidth = width
            cameraHeight = height
            cameraTexture.setDefaultBufferSize(width, height)
        }
    }

    /** The clockwise rotation that makes camera buffers upright. */
    fun setRotation(rotationDegrees: Int) {
        runOnGlThread { this.rotationDegrees = rotationDegrees }
    }

    /** Attaches or (with null) detaches the encoder input. Blocks until done, so the caller can release the surface. */
    fun setEncoderSurface(surface: Surface?, width: Int = 0, height: Int = 0) = runBlocking {
        encoder = replace(encoder, surface, width, height)
    }

    /** Attaches or (with null) detaches the preview. Blocks until done, so the caller can release the surface. */
    fun setPreviewSurface(surface: Surface?, width: Int = 0, height: Int = 0) = runBlocking {
        preview = replace(preview, surface, width, height)
    }

    fun release() {
        runBlocking {
            encoder?.let { EGL14.eglDestroySurface(display, it.surface) }
            preview?.let { EGL14.eglDestroySurface(display, it.surface) }
            encoder = null
            preview = null
            cameraTexture.release()
            GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
            GLES20.glDeleteProgram(program)
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, placeholderSurface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
        thread.quitSafely()
    }

    private fun runOnGlThread(block: () -> Unit) {
        if (Thread.currentThread() == thread) block() else handler.post(block)
    }

    private fun runBlocking(block: () -> Unit) {
        if (Thread.currentThread() == thread) return block()
        val done = CountDownLatch(1)
        var failure: Throwable? = null
        handler.post {
            try {
                block()
            } catch (error: Throwable) {
                failure = error
            } finally {
                done.countDown()
            }
        }
        done.await()
        failure?.let { throw it }
    }

    private fun replace(current: Target?, surface: Surface?, width: Int, height: Int): Target? {
        if (current != null) {
            EGL14.eglMakeCurrent(display, placeholderSurface, placeholderSurface, context)
            EGL14.eglDestroySurface(display, current.surface)
        }
        if (surface == null) return null
        val eglSurface = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        check(eglSurface != EGL14.EGL_NO_SURFACE) { "eglCreateWindowSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}" }
        return Target(eglSurface, width, height)
    }

    private fun setUp() {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGLExt.EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE,
        )
        check(EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0) {
            "No recordable EGL config"
        }
        config = configs[0]!!
        context = EGL14.eglCreateContext(
            display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0
        )
        placeholderSurface = EGL14.eglCreatePbufferSurface(
            display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0
        )
        EGL14.eglMakeCurrent(display, placeholderSurface, placeholderSurface, context)

        program = linkProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        cameraTexture = SurfaceTexture(textureId).apply {
            setOnFrameAvailableListener({ drawFrame() }, handler)
        }
    }

    private fun drawFrame() {
        EGL14.eglMakeCurrent(display, placeholderSurface, placeholderSurface, context)
        cameraTexture.updateTexImage()
        cameraTexture.getTransformMatrix(stMatrix)
        encoder?.let {
            draw(it)
            EGLExt.eglPresentationTimeANDROID(display, it.surface, cameraTexture.timestamp)
            EGL14.eglSwapBuffers(display, it.surface)
        }
        preview?.let {
            draw(it)
            EGL14.eglSwapBuffers(display, it.surface)
        }
    }

    private fun draw(target: Target) {
        EGL14.eglMakeCurrent(display, target.surface, target.surface, context)
        GLES20.glViewport(0, 0, target.width, target.height)
        orientationMatrix(
            orientMatrix, rotationDegrees, cameraWidth, cameraHeight, target.width.toFloat() / target.height
        )
        Matrix.multiplyMM(texMatrix, 0, stMatrix, 0, orientMatrix, 0)

        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        val position = GLES20.glGetAttribLocation(program, "aPosition")
        val texCoord = GLES20.glGetAttribLocation(program, "aTexCoord")
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTexMatrix"), 1, false, texMatrix, 0)
        GLES20.glEnableVertexAttribArray(position)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, QUAD_POSITIONS)
        GLES20.glEnableVertexAttribArray(texCoord)
        GLES20.glVertexAttribPointer(texCoord, 2, GLES20.GL_FLOAT, false, 0, QUAD_TEX_COORDS)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    companion object {
        /**
         * Column-major matrix mapping output texture coordinates (GL convention, y up) to camera buffer coordinates:
         * mirror horizontally, center-crop the upright image to [outputAspect], then undo the camera's clockwise
         * [rotationDegrees].
         */
        fun orientationMatrix(
            out: FloatArray,
            rotationDegrees: Int,
            bufferWidth: Int,
            bufferHeight: Int,
            outputAspect: Float,
        ) {
            val quarterTurns = ((rotationDegrees / 90) % 4 + 4) % 4
            val radians = Math.toRadians(quarterTurns * 90.0)
            val c = cos(radians).roundToInt().toFloat()
            val s = sin(radians).roundToInt().toFloat()
            val sideways = quarterTurns % 2 == 1
            val contentAspect = when {
                bufferWidth <= 0 || bufferHeight <= 0 -> outputAspect
                sideways -> bufferHeight.toFloat() / bufferWidth
                else -> bufferWidth.toFloat() / bufferHeight
            }
            val scaleX = if (contentAspect > outputAspect) outputAspect / contentAspect else 1f
            val scaleY = if (contentAspect > outputAspect) 1f else contentAspect / outputAspect
            // b = rotateCounterClockwise(mirror(u) scaled about the center)
            val a11 = -c * scaleX
            val a12 = -s * scaleY
            val a21 = -s * scaleX
            val a22 = c * scaleY
            out.fill(0f)
            out[0] = a11
            out[1] = a21
            out[4] = a12
            out[5] = a22
            out[10] = 1f
            out[12] = 0.5f - 0.5f * (a11 + a12)
            out[13] = 0.5f - 0.5f * (a21 + a22)
            out[15] = 1f
        }

        private const val VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec4 aTexCoord;
            uniform mat4 uTexMatrix;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = (uTexMatrix * aTexCoord).xy;
            }
        """

        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTexCoord;
            uniform samplerExternalOES sTexture;
            void main() {
                gl_FragColor = texture2D(sTexture, vTexCoord);
            }
        """

        private val QUAD_POSITIONS = floatBuffer(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f)
        private val QUAD_TEX_COORDS = floatBuffer(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f)

        private fun floatBuffer(vararg values: Float): FloatBuffer =
            ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
                put(values)
                position(0)
            }

        private fun linkProgram(vertexSource: String, fragmentSource: String): Int {
            val program = GLES20.glCreateProgram()
            GLES20.glAttachShader(program, compileShader(GLES20.GL_VERTEX_SHADER, vertexSource))
            GLES20.glAttachShader(program, compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource))
            GLES20.glLinkProgram(program)
            val status = IntArray(1)
            GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
            check(status[0] == GLES20.GL_TRUE) { "Program link failed: ${GLES20.glGetProgramInfoLog(program)}" }
            return program
        }

        private fun compileShader(type: Int, source: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source.trimIndent())
            GLES20.glCompileShader(shader)
            val status = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
            check(status[0] == GLES20.GL_TRUE) { "Shader compile failed: ${GLES20.glGetShaderInfoLog(shader)}" }
            return shader
        }
    }
}

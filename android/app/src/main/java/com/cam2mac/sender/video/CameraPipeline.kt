package com.cam2mac.sender.video

import android.content.Context
import android.util.Size
import android.view.Surface
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner

/** Feeds the front camera into [renderer]'s SurfaceTexture through a CameraX Preview use case. */
class CameraPipeline(private val context: Context, private val renderer: GlFrameRenderer) {
    private var provider: ProcessCameraProvider? = null
    private var preview: Preview? = null

    fun bind(lifecycleOwner: LifecycleOwner, onError: (Exception) -> Unit) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                val provider = future.get().also { provider = it }
                val preview = Preview.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(1280, 720),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                )
                            )
                            .build()
                    )
                    .build()
                    .also { preview = it }
                preview.setSurfaceProvider(renderer.executor) { request ->
                    renderer.setCameraInput(request.resolution.width, request.resolution.height)
                    request.setTransformationInfoListener(renderer.executor) { info ->
                        renderer.setRotation(info.rotationDegrees)
                    }
                    val surface = Surface(renderer.cameraTexture)
                    request.provideSurface(surface, renderer.executor) { surface.release() }
                }
                provider.unbindAll()
                provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_FRONT_CAMERA, preview)
            } catch (error: Exception) {
                onError(error)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    fun unbind() {
        preview?.let { provider?.unbind(it) }
        preview = null
    }
}

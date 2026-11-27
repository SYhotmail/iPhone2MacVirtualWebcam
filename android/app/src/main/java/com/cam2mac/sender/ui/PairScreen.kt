package com.cam2mac.sender.ui

import androidx.annotation.OptIn
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.cam2mac.sender.pairing.PairingInvitation
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Scans the pairing QR code the Mac app shows. */
@Composable
fun PairScreen(onInvitation: (PairingInvitation) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOnInvitation by rememberUpdatedState(onInvitation)
    var message by remember { mutableStateOf("Point the camera at the pairing code in the Cam2Mac app on your Mac.") }
    val previewView = remember { PreviewView(context) }

    DisposableEffect(lifecycleOwner) {
        val analysisExecutor = Executors.newSingleThreadExecutor()
        val scanner = BarcodeScanning.getClient(
            BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
        )
        val found = AtomicBoolean(false)
        val analysis = ImageAnalysis.Builder()
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        analysis.setAnalyzer(analysisExecutor, @OptIn(ExperimentalGetImage::class) { proxy ->
            val image = proxy.image
            if (image == null || found.get()) {
                proxy.close()
                return@setAnalyzer
            }
            scanner.process(InputImage.fromMediaImage(image, proxy.imageInfo.rotationDegrees))
                .addOnSuccessListener { codes ->
                    val values = codes.mapNotNull { it.rawValue }
                    val invitation = values.firstNotNullOfOrNull(PairingInvitation::parse)
                    if (invitation != null && found.compareAndSet(false, true)) {
                        currentOnInvitation(invitation)
                    } else if (values.isNotEmpty()) {
                        message = "That is not a Cam2Mac pairing code."
                    }
                }
                .addOnCompleteListener { proxy.close() }
        })
        val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }

        var disposed = false
        val providerFuture = ProcessCameraProvider.getInstance(context)
        providerFuture.addListener({
            // The screen may be gone before the provider is ready (both run on the main thread).
            if (disposed) return@addListener
            val provider = providerFuture.get()
            val selector = if (provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)) {
                CameraSelector.DEFAULT_BACK_CAMERA
            } else {
                CameraSelector.DEFAULT_FRONT_CAMERA
            }
            provider.unbindAll()
            provider.bindToLifecycle(lifecycleOwner, selector, preview, analysis)
        }, ContextCompat.getMainExecutor(context))

        onDispose {
            disposed = true
            if (providerFuture.isDone) providerFuture.get().unbind(preview, analysis)
            scanner.close()
            analysisExecutor.shutdown()
        }
    }

    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("Pair with your Mac", style = MaterialTheme.typography.headlineSmall)
        AndroidView({ previewView }, Modifier.fillMaxWidth().aspectRatio(3f / 4f))
        Text(message, textAlign = TextAlign.Center)
    }
}

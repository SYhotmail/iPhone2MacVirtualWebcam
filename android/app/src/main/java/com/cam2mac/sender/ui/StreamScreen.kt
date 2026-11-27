package com.cam2mac.sender.ui

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.cam2mac.sender.pairing.PairedMac
import com.cam2mac.sender.transport.StreamStatus
import com.cam2mac.sender.video.CameraPipeline

/** Front-camera preview with Start/Stop streaming to the paired Mac. */
@Composable
fun StreamScreen(viewModel: SenderViewModel, mac: PairedMac) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val status by viewModel.status.collectAsStateWithLifecycle()
    val isStreaming by viewModel.isStreaming.collectAsStateWithLifecycle()
    var cameraError by remember { mutableStateOf<String?>(null) }

    DisposableEffect(lifecycleOwner) {
        val pipeline = CameraPipeline(context, viewModel.renderer)
        pipeline.bind(lifecycleOwner) { cameraError = it.message ?: "Could not open the front camera" }
        onDispose { pipeline.unbind() }
    }

    val view = LocalView.current
    DisposableEffect(isStreaming) {
        view.keepScreenOn = isStreaming
        onDispose { view.keepScreenOn = false }
    }

    Column(
        Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        AndroidView(
            factory = { viewContext ->
                SurfaceView(viewContext).apply {
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) = Unit

                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                            viewModel.renderer.setPreviewSurface(holder.surface, width, height)
                        }

                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            viewModel.renderer.setPreviewSurface(null)
                        }
                    })
                }
            },
            modifier = Modifier.weight(1f).aspectRatio(9f / 16f),
        )

        Text("Mac: ${mac.serviceName}", style = MaterialTheme.typography.titleMedium)
        Text(cameraError ?: status.description(), textAlign = TextAlign.Center)

        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Button(
                onClick = { if (isStreaming) viewModel.stop() else viewModel.start() },
                modifier = Modifier.weight(1f),
            ) {
                Text(if (isStreaming) "Stop" else "Start")
            }
            OutlinedButton(onClick = viewModel::forgetMac, modifier = Modifier.weight(1f)) {
                Text("Forget Mac")
            }
        }
    }
}

private fun StreamStatus.description(): String = when (this) {
    StreamStatus.Idle -> "Not streaming"
    StreamStatus.Connecting -> "Connecting…"
    StreamStatus.Streaming -> "Streaming"
    is StreamStatus.Retrying -> "Reconnecting: $reason"
    is StreamStatus.Failed -> reason
}

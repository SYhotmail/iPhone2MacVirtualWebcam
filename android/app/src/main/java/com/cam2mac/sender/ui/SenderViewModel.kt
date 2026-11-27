package com.cam2mac.sender.ui

import android.app.Application
import android.os.Build
import android.provider.Settings
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.cam2mac.sender.pairing.PairedMac
import com.cam2mac.sender.pairing.PairingHello
import com.cam2mac.sender.pairing.PairingInvitation
import com.cam2mac.sender.pairing.PairingStore
import com.cam2mac.sender.transport.FrameStreamClient
import com.cam2mac.sender.transport.PinnedTrust
import com.cam2mac.sender.transport.ReceiverDiscovery
import com.cam2mac.sender.transport.StreamStatus
import com.cam2mac.sender.video.GlFrameRenderer
import com.cam2mac.sender.video.HevcEncoder
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicReference

sealed interface PairingState {
    data object Loading : PairingState
    data object Unpaired : PairingState
    class Paired(val mac: PairedMac) : PairingState
}

class SenderViewModel(application: Application) : AndroidViewModel(application) {
    private val store = PairingStore(application)
    private val discovery = ReceiverDiscovery(application)
    val renderer = GlFrameRenderer()

    val pairing: StateFlow<PairingState> = store.pairedMac
        .map { mac -> if (mac == null) PairingState.Unpaired else PairingState.Paired(mac) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, PairingState.Loading)

    private val _status = MutableStateFlow<StreamStatus>(StreamStatus.Idle)
    val status: StateFlow<StreamStatus> = _status.asStateFlow()

    private val _isStreaming = MutableStateFlow(false)
    val isStreaming: StateFlow<Boolean> = _isStreaming.asStateFlow()

    @Volatile private var client: FrameStreamClient? = null
    private var encoder: HevcEncoder? = null
    private var statusJob: Job? = null

    fun pair(invitation: PairingInvitation) {
        viewModelScope.launch {
            // Create the identity first, so a pairing saved below is never discarded by an identity reset.
            store.identity()
            store.save(invitation)
        }
    }

    fun forgetMac() {
        stop()
        _status.value = StreamStatus.Idle
        viewModelScope.launch { store.forgetMac() }
    }

    fun start() {
        if (_isStreaming.value) return
        _isStreaming.value = true
        viewModelScope.launch {
            val identity = store.identity()
            val mac = store.pairedMac.first()
            if (mac == null || !_isStreaming.value) {
                _isStreaming.value = false
                return@launch
            }
            val pendingToken = AtomicReference(mac.pendingToken)

            val encoder = try {
                HevcEncoder(
                    onFrame = { frame -> client?.send(frame.data, frame.isKeyframe) },
                    onError = { error -> viewModelScope.launch { fail(error.message ?: "Video encoder failed") } },
                )
            } catch (error: Exception) {
                fail(error.message ?: "Could not start the video encoder")
                return@launch
            }
            this@SenderViewModel.encoder = encoder
            renderer.setEncoderSurface(encoder.inputSurface, encoder.width, encoder.height)

            val client = FrameStreamClient(
                candidates = { discovery.candidates(mac.serviceName) },
                trust = PinnedTrust(mac.fingerprint),
                hello = {
                    pendingToken.get()
                        ?.let { PairingHello.pair(it, identity.clientID, identity.secret, deviceName()) }
                        ?: PairingHello.hello(identity.clientID, identity.secret)
                },
                onAccepted = { hello ->
                    if (hello.kind == PairingHello.Kind.PAIR) {
                        pendingToken.set(null)
                        viewModelScope.launch { store.markPaired() }
                    }
                },
                onKeyframeRequest = encoder::requestKeyframe,
            )
            this@SenderViewModel.client = client
            statusJob = launch {
                client.status.collect { status ->
                    if (status is StreamStatus.Failed) fail(status.reason) else _status.value = status
                }
            }
            client.start()
        }
    }

    fun stop() {
        _isStreaming.value = false
        statusJob?.cancel()
        statusJob = null
        client?.close()
        client = null
        renderer.setEncoderSurface(null)
        encoder?.release()
        encoder = null
        _status.value = StreamStatus.Idle
    }

    private fun fail(reason: String) {
        stop()
        _status.value = StreamStatus.Failed(reason)
    }

    private fun deviceName(): String =
        Settings.Global.getString(getApplication<Application>().contentResolver, Settings.Global.DEVICE_NAME)
            ?: Build.MODEL

    override fun onCleared() {
        stop()
        renderer.release()
    }
}

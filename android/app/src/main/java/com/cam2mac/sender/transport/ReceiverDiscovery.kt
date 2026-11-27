package com.cam2mac.sender.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Finds the Mac's TLS/TCP listener through Bonjour (`_cam2mac._tcp`), by the service name from the QR code.
 * The Mac advertises its QUIC listener under the same name as `_cam2mac._udp`.
 */
class ReceiverDiscovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()

    /** Blocks until [serviceName] resolves or [timeoutMillis] pass. */
    fun resolve(serviceName: String, timeoutMillis: Long = 5_000): InetSocketAddress {
        val multicastLock = wifi.createMulticastLock("cam2mac-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
        try {
            return resolveService(serviceName, timeoutMillis)
        } finally {
            multicastLock.release()
        }
    }

    private fun resolveService(serviceName: String, timeoutMillis: Long): InetSocketAddress {
        val request = NsdServiceInfo().apply {
            this.serviceName = serviceName
            serviceType = SERVICE_TYPE
        }
        // The first callback completes it; later ones are ignored.
        val result = CompletableFuture<InetSocketAddress>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val callback = object : NsdManager.ServiceInfoCallback {
                override fun onServiceUpdated(info: NsdServiceInfo) {
                    val host = preferredAddress(info.hostAddresses) ?: return
                    result.complete(InetSocketAddress(host, info.port))
                }

                override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                    result.completeExceptionally(IOException("Bonjour lookup failed ($errorCode)"))
                }

                override fun onServiceLost() = Unit
                override fun onServiceInfoCallbackUnregistered() = Unit
            }
            nsd.registerServiceInfoCallback(request, executor, callback)
            try {
                return await(result, serviceName, timeoutMillis)
            } finally {
                runCatching { nsd.unregisterServiceInfoCallback(callback) }
            }
        }

        @Suppress("DEPRECATION")
        nsd.resolveService(request, object : NsdManager.ResolveListener {
            override fun onServiceResolved(info: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                val host = info.host
                if (host != null) {
                    result.complete(InetSocketAddress(host, info.port))
                } else {
                    result.completeExceptionally(IOException("Bonjour returned no address for $serviceName"))
                }
            }

            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                result.completeExceptionally(IOException("Could not find \"$serviceName\" ($errorCode)"))
            }
        })
        return await(result, serviceName, timeoutMillis)
    }

    private fun await(result: CompletableFuture<InetSocketAddress>, serviceName: String, timeoutMillis: Long) =
        try {
            result.get(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            throw IOException("Could not find \"$serviceName\" on this network")
        } catch (error: ExecutionException) {
            throw error.cause as? IOException ?: IOException(error.cause)
        }

    private fun preferredAddress(addresses: List<InetAddress>): InetAddress? =
        addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()

    private companion object {
        const val SERVICE_TYPE = "_cam2mac._tcp"
    }
}

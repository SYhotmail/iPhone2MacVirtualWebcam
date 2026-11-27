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
 * The QR name comes from the Mac's `_cam2mac._udp` listener; Bonjour may have renamed the `_tcp` one after a
 * name conflict, so when the exact name is not found the lookup falls back to similar names
 * ([ServiceNameMatcher]). The caller's certificate pin picks the right Mac among them.
 */
class ReceiverDiscovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()

    /**
     * Addresses to try in order, computed lazily on the calling thread: the exact [serviceName] first, then every
     * other `_cam2mac._tcp` service with a matching name. The caller stops at the first one that passes its
     * certificate pin. Throws [IOException] when nothing is found.
     */
    fun candidates(serviceName: String): Sequence<InetSocketAddress> = sequence {
        var failure: IOException? = null
        try {
            yield(resolveService(serviceName, EXACT_TIMEOUT_MILLIS))
        } catch (error: IOException) {
            failure = error
        }
        val similarNames = ServiceNameMatcher.ranked(serviceName, browse(BROWSE_MILLIS)).filter { it != serviceName }
        for (name in similarNames) {
            try {
                yield(resolveService(name, EXACT_TIMEOUT_MILLIS))
                failure = null
            } catch (error: IOException) {
                failure = failure ?: error
            }
        }
        failure?.let { throw it }
    }

    private inline fun <T> withMulticastLock(block: () -> T): T {
        val multicastLock = wifi.createMulticastLock("cam2mac-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
        try {
            return block()
        } finally {
            multicastLock.release()
        }
    }

    /** Names of the `_cam2mac._tcp` services seen within [durationMillis]. */
    private fun browse(durationMillis: Long): Set<String> = withMulticastLock {
        val names = java.util.Collections.synchronizedSet(mutableSetOf<String>())
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                names += info.serviceName
            }

            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        try {
            Thread.sleep(durationMillis)
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
        names.toSet()
    }

    private fun resolveService(serviceName: String, timeoutMillis: Long): InetSocketAddress =
        withMulticastLock { resolveUnlocked(serviceName, timeoutMillis) }

    private fun resolveUnlocked(serviceName: String, timeoutMillis: Long): InetSocketAddress {
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
        const val EXACT_TIMEOUT_MILLIS = 3_000L
        const val BROWSE_MILLIS = 2_000L
    }
}

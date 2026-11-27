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
import java.util.Collections
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Finds the Mac's TLS/TCP listener through Bonjour (`_cam2mac._tcp`), by the service name from the QR code.
 * The QR name comes from the Mac's `_cam2mac._udp` listener; Bonjour may have renamed the `_tcp` one after a
 * name conflict, so similar names are tried too ([ServiceNameMatcher]). The caller's certificate pin picks the
 * right Mac among them.
 */
class ReceiverDiscovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()

    /**
     * Addresses to try in order, computed lazily on the calling thread: browses `_cam2mac._tcp` (stopping early
     * once the exact name shows up), then resolves the matching names one by one, exact name first. The caller
     * stops at the first one that passes its certificate pin. Throws [IOException] when nothing resolves.
     */
    fun candidates(serviceName: String): Sequence<InetSocketAddress> = sequence {
        val names = ServiceNameMatcher.ranked(serviceName, browse(serviceName))
        if (names.isEmpty()) throw IOException("Could not find \"$serviceName\" on this network")
        var failure: IOException? = null
        var found = false
        for (name in names) {
            try {
                val address = resolve(name)
                found = true
                yield(address)
            } catch (error: IOException) {
                failure = failure ?: error
            }
        }
        if (!found) throw failure ?: IOException("Could not find \"$serviceName\" on this network")
    }

    /** Names of the `_cam2mac._tcp` services seen within [BROWSE_MILLIS], or sooner once [exactName] appears. */
    private fun browse(exactName: String): Set<String> = withMulticastLock {
        val names = Collections.synchronizedSet(mutableSetOf<String>())
        val exactFound = CountDownLatch(1)
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                names += info.serviceName
                if (info.serviceName == exactName) exactFound.countDown()
            }

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = exactFound.countDown()
            override fun onServiceLost(info: NsdServiceInfo) = Unit
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
        try {
            exactFound.await(BROWSE_MILLIS, TimeUnit.MILLISECONDS)
        } finally {
            runCatching { nsd.stopServiceDiscovery(listener) }
        }
        names.toSet()
    }

    private fun resolve(serviceName: String): InetSocketAddress = withMulticastLock {
        val release = resolveSlot.acquire(RESOLVE_TIMEOUT_MILLIS)
            ?: throw IOException("Bonjour is still busy with an earlier lookup")
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
            try {
                nsd.registerServiceInfoCallback(request, executor, callback)
                return@withMulticastLock await(result, serviceName)
            } finally {
                // Unregistering cancels a lookup that timed out, so the slot is free again right away.
                runCatching { nsd.unregisterServiceInfoCallback(callback) }
                release()
            }
        }

        // Before API 34 a resolve cannot be cancelled: the slot is released by its callback, not by a timeout.
        try {
            @Suppress("DEPRECATION")
            nsd.resolveService(request, object : NsdManager.ResolveListener {
                override fun onServiceResolved(info: NsdServiceInfo) {
                    release()
                    @Suppress("DEPRECATION")
                    val host = info.host
                    if (host != null) {
                        result.complete(InetSocketAddress(host, info.port))
                    } else {
                        result.completeExceptionally(IOException("Bonjour returned no address for $serviceName"))
                    }
                }

                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    release()
                    result.completeExceptionally(IOException("Could not resolve \"$serviceName\" ($errorCode)"))
                }
            })
        } catch (error: RuntimeException) {
            release()
            throw error
        }
        await(result, serviceName)
    }

    private fun await(result: CompletableFuture<InetSocketAddress>, serviceName: String) =
        try {
            result.get(RESOLVE_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
        } catch (_: TimeoutException) {
            throw IOException("Could not resolve \"$serviceName\" on this network")
        } catch (error: ExecutionException) {
            throw error.cause as? IOException ?: IOException(error.cause)
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

    private fun preferredAddress(addresses: List<InetAddress>): InetAddress? =
        addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()

    private companion object {
        const val SERVICE_TYPE = "_cam2mac._tcp"
        const val BROWSE_MILLIS = 3_000L
        const val RESOLVE_TIMEOUT_MILLIS = 3_000L

        /** NsdManager's one-resolve limit applies per process, so all instances share the slot. */
        val resolveSlot = ResolveSlot()
    }
}

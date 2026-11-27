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
 * Finds the Mac's QUIC listener through Bonjour (`_cam2mac._udp`, as the iPhone app does), by the exact service
 * name from the QR code, which comes from that same listener.
 */
class ReceiverDiscovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val wifi = context.applicationContext.getSystemService(WifiManager::class.java)
    private val executor = Executors.newSingleThreadExecutor()

    /**
     * Addresses of [serviceName] to try in order (IPv4 first), resolved on the calling thread when the sequence is
     * iterated. The caller stops at the first one that passes its certificate pin. Throws [IOException] when the
     * name does not resolve.
     */
    fun candidates(serviceName: String): Sequence<InetSocketAddress> = sequence { yieldAll(resolve(serviceName)) }

    private fun resolve(serviceName: String): List<InetSocketAddress> = withMulticastLock {
        val release = resolveSlot.acquire(RESOLVE_TIMEOUT_MILLIS)
            ?: throw IOException("Bonjour is still busy with an earlier lookup")
        val request = NsdServiceInfo().apply {
            this.serviceName = serviceName
            serviceType = SERVICE_TYPE
        }
        // The first callback completes it; later ones are ignored.
        val result = CompletableFuture<List<InetSocketAddress>>()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val callback = object : NsdManager.ServiceInfoCallback {
                override fun onServiceUpdated(info: NsdServiceInfo) {
                    if (info.hostAddresses.isEmpty()) return
                    result.complete(ordered(info.hostAddresses).map { InetSocketAddress(it, info.port) })
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
                        result.complete(listOf(InetSocketAddress(host, info.port)))
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

    private fun await(result: CompletableFuture<List<InetSocketAddress>>, serviceName: String) =
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

    /** IPv4 first: an IPv6 link-local address needs a scope that NSD may not report. */
    private fun ordered(addresses: List<InetAddress>): List<InetAddress> = addresses.sortedBy { it !is Inet4Address }

    private companion object {
        const val SERVICE_TYPE = "_cam2mac._udp"
        const val RESOLVE_TIMEOUT_MILLIS = 3_000L

        /** NsdManager's one-resolve limit applies per process, so all instances share the slot. */
        val resolveSlot = ResolveSlot()
    }
}

package com.cam2mac.sender.transport

/**
 * Bonjour renames conflicting services per type, so the Mac's `_cam2mac._tcp` service can be "Studio Mac (2)"
 * while the QR code carries the `_udp` name "Studio Mac" (or the other way round). This picks the `_tcp`
 * services that may be the paired Mac; the certificate pin decides which one really is.
 */
internal object ServiceNameMatcher {
    private val conflictSuffix = Regex(""" \(\d+\)$""")

    fun matches(qrName: String, candidate: String): Boolean {
        val base = baseName(qrName)
        return candidate == qrName || baseName(candidate) == base || candidate.startsWith(base)
    }

    /** Matching names, closest first: exact, then same base name, then prefix matches. */
    fun ranked(qrName: String, candidates: Collection<String>): List<String> {
        val base = baseName(qrName)
        return candidates.distinct().filter { matches(qrName, it) }.sortedBy {
            when {
                it == qrName -> 0
                baseName(it) == base -> 1
                else -> 2
            }
        }
    }

    private fun baseName(name: String) = name.replace(conflictSuffix, "")
}

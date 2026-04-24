import Foundation
import Darwin

enum LocalNetworkAddressProvider {
    static func ipv4Addresses() -> [String] {
        var addresses = [String]()
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }

        defer {
            freeifaddrs(pointer)
        }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            let addressFamily = interface.pointee.ifa_addr.pointee.sa_family

            guard addressFamily == UInt8(AF_INET) else { continue }
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.pointee.ifa_addr,
                socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else { continue }

            let address = String(cString: hostBuffer)
            if !addresses.contains(address) {
                addresses.append(address)
            }
        }

        return addresses.sorted()
    }
}

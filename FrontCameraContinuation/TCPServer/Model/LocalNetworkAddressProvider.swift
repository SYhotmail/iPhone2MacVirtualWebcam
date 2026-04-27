import Foundation
import Darwin

nonisolated
struct IPVersionType: OptionSet {
    let rawValue: Int

    static let ipv4 = IPVersionType(rawValue: 1 << 0)
    static let ipv6 = IPVersionType(rawValue: 1 << 1)
}

protocol IPAddressProvidable {
    @concurrent
    func getIPAddresses(ipVersion: IPVersionType) async -> [Int: [String]]
    
    @concurrent
    func getIPv4Addresses() async -> [String]
}

nonisolated
struct LocalNetworkAddressProvider: IPAddressProvidable {
    
    @concurrent
    func getIPv4Addresses() async -> [String] {
        await getIPAddresses(ipVersion: .ipv4).flatMap { $0.value }
    }
    
    @concurrent
    func getIPAddresses(ipVersion: IPVersionType) async -> [Int: [String]] {
        let task = Task { @concurrent in
            assert(!Thread.isMainThread)
            var dic = [Int: [String]]()
            if ipVersion.contains(.ipv4) {
                dic[IPVersionType.ipv4.rawValue] = getIPAddresses(ipv4: true)
            } else if ipVersion.contains(.ipv6) {
                dic[IPVersionType.ipv6.rawValue] = getIPAddresses(ipv4: false)
            }
            
            return dic
        }
        
        return await task.value
    }
    
    private func getIPAddresses(ipv4: Bool) -> [String]{
        var addresses = [String]()
        var pointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }

        defer {
            freeifaddrs(pointer)
        }
        
        let version = ipv4 ? AF_INET : AF_INET6
        
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            let addressFamily = interface.pointee.ifa_addr.pointee.sa_family

            guard addressFamily == UInt8(version) else { continue }
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

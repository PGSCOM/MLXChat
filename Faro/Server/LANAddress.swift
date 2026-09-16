import Foundation

/// Interface names aren't API — Apple's own guidance is that `en0` isn't
/// guaranteed to be Wi-Fi (Ethernet adapters, hotspot, VPNs all shuffle
/// it). So this lists every active IPv4 address and lets the person
/// running the server pick the right one, instead of guessing.
enum LANAddress {
    struct Interface: Identifiable, Sendable, Hashable {
        var id: String { name + ip }
        let name: String
        let ip: String
        var isLikelyCellular: Bool { name.hasPrefix("pdp_ip") }
    }

    static func activeIPv4Addresses() -> [Interface] {
        var results: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            let name = String(cString: current.pointee.ifa_name)
            results.append(Interface(name: name, ip: String(cString: host)))
        }

        // Wi-Fi / Ethernet first, cellular last — cellular is rarely
        // reachable from a LAN client and usually behind CGNAT anyway.
        return results.sorted { lhs, rhs in
            lhs.isLikelyCellular == rhs.isLikelyCellular ? lhs.name < rhs.name : !lhs.isLikelyCellular
        }
    }
}

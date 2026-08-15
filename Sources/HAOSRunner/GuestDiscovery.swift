import Foundation

enum MACAddress {
    static func normalized(_ raw: String) -> String? {
        let octets = raw.lowercased().components(separatedBy: ":")
        guard octets.count == 6 else { return nil }
        var normalized: [String] = []
        for octet in octets {
            guard !octet.isEmpty, octet.count <= 2, let value = UInt8(octet, radix: 16) else { return nil }
            normalized.append(String(value, radix: 16))
        }
        return normalized.joined(separator: ":")
    }
}

enum DHCPLeases {
    static let filePath = "/var/db/dhcpd_leases"

    static func ipAddress(forMAC mac: String, in fileText: String) -> String? {
        guard let wanted = MACAddress.normalized(mac) else { return nil }
        var blockIP: String?
        for line in fileText.components(separatedBy: "\n") {
            let entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasPrefix("{") { blockIP = nil }
            if entry.hasPrefix("ip_address=") {
                blockIP = String(entry.dropFirst("ip_address=".count))
            }
            if entry.hasPrefix("hw_address=") {
                let value = entry.dropFirst("hw_address=".count)
                let candidate = value.split(separator: ",").last.map(String.init) ?? ""
                if MACAddress.normalized(candidate) == wanted, let ip = blockIP { return ip }
            }
        }
        return nil
    }
}

enum ARPTable {
    static func ipAddress(forMAC mac: String, in tableText: String) -> String? {
        guard let wanted = MACAddress.normalized(mac) else { return nil }
        for line in tableText.components(separatedBy: "\n") {
            guard let open = line.firstIndex(of: "("),
                  let close = line.firstIndex(of: ")"), open < close,
                  let atRange = line.range(of: " at ") else { continue }
            let candidate = line[atRange.upperBound...].components(separatedBy: " ").first ?? ""
            guard MACAddress.normalized(candidate) == wanted else { continue }
            return String(line[line.index(after: open)..<close])
        }
        return nil
    }
}

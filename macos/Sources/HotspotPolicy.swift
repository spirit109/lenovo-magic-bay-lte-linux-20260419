import Foundation

struct HotspotFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

struct HotspotUpstream: Codable, Equatable {
    var pid: Int32
    var started: String
    var executable: String
    var interface: String
    var address: String
    var gateway: String
    var dns: [String]
    var proxy: String
}

enum HotspotPolicy {
    // The service published by both existing MBIM backends. The interface is
    // resolved live; a particular utun number is never persisted as authority.
    static let serviceID = "7E2F4BC0-4241-4C54-8B49-4D42494D4C54"

    static func enabled(_ nat: [String: Any]) -> Bool {
        (nat["Enabled"] as? NSNumber)?.boolValue == true
    }

    static func configuration(original: [String: Any], upstream: HotspotUpstream,
                              wifi: String, wifiActive: Bool, powered: Bool,
                              ssid: String, security: String) throws -> [String: Any] {
        guard !enabled(original) else { throw HotspotFailure("已有互联网共享正在启用，拒绝接管。") }
        guard upstream.interface.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil,
              wifi.range(of: #"^en[0-9]+$"#, options: .regularExpression) != nil else {
            throw HotspotFailure("LTE 或 Wi-Fi 接口身份不完整。")
        }
        guard powered, !wifiActive else { throw HotspotFailure("Wi-Fi 必须已开启且未连接其他网络；本工具不会断开 Wi-Fi。") }
        guard !ssid.isEmpty, ssid.utf8.count <= 32,
              ["WPA2 Personal", "WPA3 Personal", "WPA2/WPA3 Personal"].contains(security) else {
            throw HotspotFailure("请先在 macOS 互联网共享中配置带 WPA2/WPA3 密码保护的热点。")
        }
        guard original["NatType"] as? String != "Nat64" else {
            throw HotspotFailure("现有配置为 NAT64，与当前 IPv4 LTE 方案不符。")
        }
        var result = original
        result["Enabled"] = 1
        result["PrimaryService"] = serviceID
        result["SharingDevices"] = [wifi]
        var primary = original["PrimaryInterface"] as? [String: Any] ?? [:]
        primary["Device"] = upstream.interface
        primary["Enabled"] = 1
        primary["HardwareKey"] = ""
        primary["PrimaryUserReadable"] = "Magic Bay LTE"
        result["PrimaryInterface"] = primary
        var airport = original["AirPort"] as? [String: Any] ?? [:]
        airport["Enabled"] = 1
        result["AirPort"] = airport
        return result
    }

    static func sameConfiguration(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }

    static func restored(current: [String: Any], applied: [String: Any],
                         original: [String: Any]) throws -> [String: Any] {
        if sameConfiguration(current, original) { return original }
        guard current["PrimaryService"] as? String == applied["PrimaryService"] as? String,
              current["SharingDevices"] as? [String] == applied["SharingDevices"] as? [String] else {
            throw HotspotFailure("共享配置已被其他操作改变，拒绝覆盖；请先检查当前系统共享设置。")
        }
        var restored = current
        for key in ["Enabled", "PrimaryService", "PrimaryInterface", "SharingDevices"] {
            restored[key] = original[key]
        }
        var airport = current["AirPort"] as? [String: Any] ?? [:]
        airport["Enabled"] = (original["AirPort"] as? [String: Any])?["Enabled"]
        restored["AirPort"] = airport.isEmpty && original["AirPort"] == nil ? nil : airport
        return restored
    }
}

enum HotspotGuardDecision: Equatable { case wait, restore, monitor }

enum HotspotGuardPolicy {
    static func decide(elapsed: TimeInterval, confirmed: Bool, activationReady: Bool,
                       restoreRequested: Bool, failures: Int, timeout: TimeInterval = 120) -> HotspotGuardDecision {
        if restoreRequested || failures >= 2 || (!confirmed && elapsed >= timeout) { return .restore }
        return activationReady ? .monitor : .wait
    }
}

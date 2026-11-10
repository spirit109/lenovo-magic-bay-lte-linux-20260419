import Foundation

@main struct HotspotTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        count += 1
        guard value() else { fputs("FAIL \(name)\n", stderr); exit(1) }
        print("PASS \(name)")
    }
    static func rejected(_ name: String, _ work: () throws -> Void) {
        do { try work(); check(false, name) } catch { check(true, name) }
    }
    static func main() throws {
        let upstream = HotspotUpstream(pid: 42, started: "test", executable: "/test/mbim-net", interface: "utun7",
                                       address: "192.0.2.2", gateway: "192.0.2.1", dns: ["192.0.2.53"], proxy: "")
        let original: [String: Any] = ["Enabled": 0, "PrimaryService": "old-service", "SharingDevices": ["en3"],
                                       "AirPort": ["Enabled": 0, "NetworkPassword": Data([1, 2, 3])],
                                       "UnknownFutureSetting": ["preserve": true], "NatPortMapDisabled": true]
        func plan(_ nat: [String: Any] = original, wifi: String = "en0", active: Bool = false,
                  power: Bool = true, ssid: String = "测试热点", security: String = "WPA2/WPA3 Personal") throws -> [String: Any] {
            try HotspotPolicy.configuration(original: nat, upstream: upstream, wifi: wifi,
                                             wifiActive: active, powered: power, ssid: ssid, security: security)
        }
        let applied = try plan()
        check(applied["PrimaryService"] as? String == HotspotPolicy.serviceID, "bind MBIM service instead of guessing primary VPN")
        check((applied["PrimaryInterface"] as? [String: Any])?["Device"] as? String == "utun7", "resolve changing utun number")
        check(applied["SharingDevices"] as? [String] == ["en0"], "share only to selected Wi-Fi")
        check((applied["AirPort"] as? [String: Any])?["NetworkPassword"] as? Data == Data([1, 2, 3]), "retain opaque password without decoding it")
        check((applied["UnknownFutureSetting"] as? [String: Bool])?["preserve"] == true, "preserve unrelated future settings")
        check(applied["NatPortMapDisabled"] as? Bool == true, "preserve port mapping policy")
        check(!HotspotPolicy.enabled(original), "planning leaves original untouched")
        rejected("never take over existing sharing") { _ = try plan(applied) }
        rejected("never disconnect active Wi-Fi") { _ = try plan(active: true) }
        rejected("never turn on powered-off Wi-Fi implicitly") { _ = try plan(power: false) }
        rejected("reject open hotspot") { _ = try plan(security: "Open") }
        rejected("reject legacy WEP") { _ = try plan(security: "WEP") }
        rejected("reject empty SSID") { _ = try plan(ssid: "") }
        rejected("SSID size is measured in UTF-8 bytes") { _ = try plan(ssid: String(repeating: "网", count: 11)) }
        rejected("Wi-Fi interface is not an arbitrary command") { _ = try plan(wifi: "en0; id") }
        var nat64 = original
        nat64["NatType"] = "Nat64"
        rejected("reject incompatible NAT64 settings") { _ = try plan(nat64) }
        let restored = try HotspotPolicy.restored(current: applied, applied: applied, original: original)
        check(HotspotPolicy.sameConfiguration(restored, original), "restore exact original configuration")
        let restoredAgain = try HotspotPolicy.restored(current: original, applied: applied, original: original)
        check(HotspotPolicy.sameConfiguration(restoredAgain, original), "restore is idempotent when the watchdog already recovered")
        var unrelated = applied
        unrelated["UnrelatedSettingChangedDuringTrial"] = "keep-this"
        let merged = try HotspotPolicy.restored(current: unrelated, applied: applied, original: original)
        check(merged["UnrelatedSettingChangedDuringTrial"] as? String == "keep-this", "recovery preserves unrelated concurrent preferences")
        check(!HotspotPolicy.enabled(merged), "owned sharing is still disabled during merged recovery")
        var foreign = applied
        foreign["PrimaryService"] = "another-owner"
        rejected("restore does not overwrite another owner") {
            _ = try HotspotPolicy.restored(current: foreign, applied: applied, original: original)
        }
        var reconnected = upstream
        reconnected.started = "new connection with reused PID"
        check(reconnected != upstream, "PID reuse changes upstream identity")
        reconnected = upstream
        reconnected.dns = ["198.51.100.53"]
        check(reconnected != upstream, "upstream DNS change is detected")
        check(HotspotGuardPolicy.decide(elapsed: 1, confirmed: false, activationReady: false, restoreRequested: false, failures: 0) == .wait, "guard arms before activation")
        check(HotspotGuardPolicy.decide(elapsed: 120, confirmed: false, activationReady: true, restoreRequested: false, failures: 0) == .restore, "unconfirmed trial rolls back without the chat")
        check(HotspotGuardPolicy.decide(elapsed: 121, confirmed: true, activationReady: true, restoreRequested: false, failures: 0) == .monitor, "confirmation retains local health monitoring")
        check(HotspotGuardPolicy.decide(elapsed: 10, confirmed: true, activationReady: true, restoreRequested: true, failures: 0) == .restore, "one-click recovery overrides confirmation")
        check(HotspotGuardPolicy.decide(elapsed: 20, confirmed: true, activationReady: true, restoreRequested: false, failures: 2) == .restore, "consecutive network failures restore even after confirmation")
        check(HotspotGuardPolicy.decide(elapsed: 20, confirmed: true, activationReady: true, restoreRequested: false, failures: 1) == .monitor, "one failed endpoint sample is not enough to claim network loss")
        print("ALL \(count) HOTSPOT POLICY TESTS PASSED; no system settings, Wi-Fi or USB changed")
    }
}

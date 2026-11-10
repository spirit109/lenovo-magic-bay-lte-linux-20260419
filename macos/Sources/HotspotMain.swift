import Foundation
import SystemConfiguration
import Darwin

// Independent macOS sidecar. Does not install helpers, issue MBIM commands,
// edit DNS/proxies, or load/flush the PF ruleset. Recovery can re-add a missing
// default route only while the original MBIM process and IP are still verified.
@main struct HotspotMain {
    static let runner = CommandRunner()
    static let fm = FileManager.default
    static let natPath = "/Library/Preferences/SystemConfiguration/com.apple.nat.plist"
    static let airportPath = "/Library/Preferences/SystemConfiguration/com.apple.airport.preferences.plist"

    struct Context {
        let upstream: HotspotUpstream
        let nat: [String: Any]
        let proposed: [String: Any]
        let wifi: String
        let ssid: String
        let security: String
    }

    static func command(_ path: String, _ arguments: [String]) throws -> String {
        let result = runner.run(path, arguments, timeout: 5)
        guard result.code == 0 else { throw HotspotFailure("只读检查失败：\(path)，code=\(result.code)") }
        return result.output
    }

    static func dictionary(at path: String) throws -> [String: Any] {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0, info.st_mode & 0o022 == 0, info.st_size < 4_194_304 else {
            throw HotspotFailure("配置文件缺失或权限不可信：\(path)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw HotspotFailure("无法解析配置：\(path)")
        }
        return value
    }

    static func currentNAT() throws -> [String: Any] {
        guard let nat = try dictionary(at: natPath)["NAT"] as? [String: Any] else {
            throw HotspotFailure("系统没有现成的共享配置，请先在系统设置中配置热点。")
        }
        return nat
    }

    static func upstream() throws -> HotspotUpstream {
        let inventory = MacInspector().processes()
        let helpers = inventory.entries.filter { URL(fileURLWithPath: $0.executable).lastPathComponent == "mbim-net" }
        guard inventory.available, helpers.count == 1, let process = helpers.first, process.uid == 0,
              ConnectionPolicy.isManagedHelper(process.executable) || ConnectionPolicy.isLegacyBundleHelper(process.executable),
              !inventory.entries.contains(where: { URL(fileURLWithPath: $0.executable).lastPathComponent.hasPrefix("mbim-probe") }) else {
            throw HotspotFailure("无法确认唯一且可信的 Magic Bay 后台，已暂停共享。")
        }
        guard let store = SCDynamicStoreCreate(nil, "MagicBayHotspotReadOnly" as CFString, nil, nil),
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(HotspotPolicy.serviceID)/IPv4" as CFString) as? [String: Any],
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(HotspotPolicy.serviceID)/DNS" as CFString) as? [String: Any],
              let interface = ipv4["InterfaceName"] as? String,
              let address = (ipv4["Addresses"] as? [String])?.first,
              let gateway = ipv4["Router"] as? String,
              let servers = dns["ServerAddresses"] as? [String], !servers.isEmpty,
              dns["InterfaceName"] as? String == interface else {
            throw HotspotFailure("Magic Bay 的 IPv4/DNS 服务证据不完整。")
        }
        let route = try command("/sbin/route", ["-n", "get", "default"])
        let info = try command("/sbin/ifconfig", [interface])
        guard Match.last(#"interface:\s*(\S+)"#, route) == interface,
              Match.last(#"gateway:\s*(\S+)"#, route) == gateway,
              Match.all(#"\binet ([0-9.]+)"#, info).contains(address) else {
            throw HotspotFailure("默认路由或接口地址不属于已识别的 LTE；本工具不会抢回路由。")
        }
        return HotspotUpstream(pid: process.pid, started: process.started, executable: process.executable,
                               interface: interface, address: address, gateway: gateway, dns: servers,
                               proxy: try command("/usr/sbin/scutil", ["--proxy"]))
    }

    static func context() throws -> Context {
        let current = try upstream()
        let sharing = try sharingState()
        guard (sharing["ap_interfaces"] as? [String])?.isEmpty == true else {
            throw HotspotFailure("已有无线热点接口处于启用状态，拒绝接管。")
        }
        let ports = try command("/usr/sbin/networksetup", ["-listallhardwareports"])
        guard let wifi = Match.last(#"Hardware Port: (?:Wi-Fi|AirPort)\s+Device: (en[0-9]+)"#, ports) else {
            throw HotspotFailure("没有找到系统 Wi-Fi 接口。")
        }
        let active = try command("/sbin/ifconfig", [wifi]).contains("status: active")
        let powered = try command("/usr/sbin/networksetup", ["-getairportpower", wifi]).contains(": On")
        let config = try dictionary(at: airportPath)["InternetSharing"] as? [String: Any] ?? [:]
        let ssid = (config["SSID"] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? (config["SSID"] as? String) ?? ""
        let security = config["SecurityType"] as? String ?? ""
        let nat = try currentNAT()
        let proposed = try HotspotPolicy.configuration(original: nat, upstream: current, wifi: wifi,
                                                       wifiActive: active, powered: powered, ssid: ssid, security: security)
        return Context(upstream: current, nat: nat, proposed: proposed, wifi: wifi, ssid: ssid, security: security)
    }

    static func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }

    static func preflight() throws {
        let state = try context()
        let check = MacInspector().probe(name: "Apple", url: "https://www.apple.com/library/test/success.html", interface: state.upstream.interface)
        let system = MacInspector().systemProbe()
        guard try upstream() == state.upstream else { throw HotspotFailure("检查期间上游身份发生变化，请重新检查。") }
        try emit(["gate": "warning", "prepared": check.outcome == .passed && system.outcome == .passed, "system_changes": false,
                  "backend_pid": state.upstream.pid, "backend_started": state.upstream.started,
                  "lte_interface": state.upstream.interface, "lte_https": check.detail, "system_https": system.detail,
                  "share_from_service": HotspotPolicy.serviceID, "share_to": state.wifi,
                  "ssid": state.ssid, "security": state.security,
                  "password": "沿用系统已保存的热点密码；不提取或显示密码，不访问钥匙串",
                  "remaining": "系统授权、热点实际启动、其他设备连接与访问验收"])
        guard check.outcome == .passed, system.outcome == .passed else { throw HotspotFailure("LTE 或系统 HTTPS 未通过，拒绝启用。") }
    }

    static func apply(expected: [String: Any], replacement: [String: Any]) throws {
        guard geteuid() == 0 else { throw HotspotFailure("需要用户通过系统授权窗口或本机终端授予管理员权限。") }
        guard let prefs = SCPreferencesCreate(nil, "MagicBayHotspot" as CFString, "com.apple.nat.plist" as CFString),
              SCPreferencesLock(prefs, false) else { throw HotspotFailure("无法锁定系统共享配置。") }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        guard let current = SCPreferencesGetValue(prefs, "NAT" as CFString) as? [String: Any],
              HotspotPolicy.sameConfiguration(current, expected) else {
            throw HotspotFailure("系统共享配置已发生变化，未覆盖。")
        }
        guard SCPreferencesSetValue(prefs, "NAT" as CFString, replacement as CFDictionary),
              SCPreferencesCommitChanges(prefs) else { throw HotspotFailure("共享配置提交失败。") }
        guard SCPreferencesApplyChanges(prefs) else {
            throw HotspotFailure("共享配置已保存，但系统未确认应用；需要按会话备份恢复。")
        }
    }

    static func save(_ value: [String: Any], name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw HotspotFailure("无法保存恢复记录，未授权继续。")
        }
    }

    static func sessionDirectory() throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent().appendingPathComponent("session-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    static func sharingState() throws -> [String: Any] {
        let output = try command("/sbin/ifconfig", ["-a"])
        var blocks = [String: String]()
        var name = ""
        for line in output.components(separatedBy: .newlines) {
            if let found = Match.last(#"^([a-z]+[0-9]+):"#, line) { name = found }
            if !name.isEmpty { blocks[name, default: ""] += line + "\n" }
        }
        let aps = blocks.filter { $0.key.hasPrefix("ap") && $0.value.contains("<UP,") }
        let bridges = blocks.filter { item in
            item.key.hasPrefix("bridge") && aps.keys.contains(where: { item.value.contains("member: " + $0 + " ") })
        }
        let addresses = bridges.values.flatMap { Match.all(#"\binet ([0-9.]+)"#, $0) }
        let inventory = MacInspector().processes()
        guard inventory.available else { throw HotspotFailure("无法检查系统共享进程。") }
        let sharing = inventory.entries.filter { $0.executable == "/usr/libexec/InternetSharing" }
        let bootpd = inventory.entries.filter { $0.executable == "/usr/libexec/bootpd" }
        let listeners = runner.run("/usr/sbin/lsof", ["-nP", "-iUDP:67", "-Fpn"], timeout: 5)
        let allowedOwners = Set((sharing + bootpd).filter { $0.uid == 0 }.map(\.pid))
        var owner: Int32?
        var dhcpListener = false
        if listeners.code == 0 {
            for line in listeners.output.split(separator: "\n") {
                if line.first == "p" { owner = Int32(line.dropFirst()) }
                if line.first == "n", line.hasSuffix(":67"), let pid = owner, allowedOwners.contains(pid) {
                    dhcpListener = true
                }
            }
        }
        let ready = !aps.isEmpty && !addresses.isEmpty && !sharing.isEmpty && dhcpListener
        return ["ap_interfaces": aps.keys.sorted(), "bridge_interfaces": bridges.keys.sorted(),
                "gateway_addresses": addresses.sorted(), "sharing_processes": sharing.map(\.pid),
                "dhcp_processes": bootpd.map(\.pid), "dhcp_listener_verified": dhcpListener,
                "ap_and_dhcp_ready": ready,
                "client_internet_verified": false, "gate": "warning"]
    }

    static func restore(_ session: URL) throws {
        guard geteuid() == 0 else { throw HotspotFailure("恢复共享配置需要管理员授权。") }
        let original = try dictionary(at: session.appendingPathComponent("original-nat.plist").path)
        let applied = try dictionary(at: session.appendingPathComponent("applied-nat.plist").path)
        let current = try currentNAT()
        let restored = try HotspotPolicy.restored(current: current, applied: applied, original: original)
        if !HotspotPolicy.sameConfiguration(current, restored) { try apply(expected: current, replacement: restored) }
        guard HotspotPolicy.sameConfiguration(try currentNAT(), restored) else {
            throw HotspotFailure("共享偏好恢复后核对失败。")
        }
        for _ in 0..<20 {
            let status = try sharingState()
            if (status["ap_interfaces"] as? [String])?.isEmpty == true {
                print("original_sharing_preferences_restored=1 hotspot_stopped=1 backup_retained=1")
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw HotspotFailure("共享偏好已恢复，但热点接口仍存在；未确认停止，不会强杀系统服务。")
    }

    static func enable(trial: Bool = false) throws {
        guard geteuid() == 0 else { throw HotspotFailure("启用热点需要管理员授权。") }
        let state = try context()
        guard health(state.upstream) else {
            throw HotspotFailure("启用前 LTE 身份或 HTTPS 检测未通过。")
        }
        let session = try sessionDirectory()
        try save(state.nat, name: "original-nat.plist", in: session)
        try save(state.proposed, name: "applied-nat.plist", in: session)
        let upstreamData = try JSONEncoder().encode(state.upstream)
        guard let upstreamRecord = try JSONSerialization.jsonObject(with: upstreamData) as? [String: Any] else {
            throw HotspotFailure("上游恢复记录生成失败。")
        }
        try save(upstreamRecord, name: "upstream.plist", in: session)
        print("recovery_session=\(session.path)")
        fflush(stdout)
        let guardProcess = try startGuard(session)
        do {
            // Re-read all preconditions immediately before the sole system write.
            let fresh = try context()
            guard fresh.upstream == state.upstream, fresh.wifi == state.wifi,
                  fresh.ssid == state.ssid, fresh.security == state.security,
                  HotspotPolicy.sameConfiguration(fresh.nat, state.nat) else {
                throw HotspotFailure("授权后现场条件已变化，未启用共享。")
            }
            guard guardProcess.isRunning else { throw HotspotFailure("独立守护已退出，未启用热点。") }
            try apply(expected: state.nat, replacement: state.proposed)
            for _ in 0..<20 {
                guard guardProcess.isRunning else { throw HotspotFailure("独立守护已退出，停止热点验收。") }
                guard try upstream() == state.upstream else {
                    throw HotspotFailure("共享启用期间 LTE、默认路由、DNS 或代理发生变化，停止验收并恢复共享设置。")
                }
                let status = try sharingState()
                if status["ap_and_dhcp_ready"] as? Bool == true {
                    let after = MacInspector().probe(name: "Apple", url: "https://www.apple.com/library/test/success.html", interface: state.upstream.interface)
                    guard after.outcome == .passed, try upstream() == state.upstream else {
                        throw HotspotFailure("热点启动后 LTE 直连复核未通过。")
                    }
                    try save(["ready": true], name: "activation-ready.plist", in: session)
                    if trial {
                        try request("restore", session: session)
                        try waitForRecovery(session)
                        try emit(["trial_complete": true, "rollback_verified": true, "hotspot_enabled": false,
                                  "recovery_session": session.path, "gate": "warning"])
                        return
                    }
                    var result = status
                    result["ssid"] = state.ssid
                    result["security"] = state.security
                    result["lte_https"] = after.detail
                    result["recovery_session"] = session.path
                    result["guard_pid"] = guardProcess.processIdentifier
                    result["requires_keep_confirmation"] = true
                    try emit(result)
                    return
                }
                Thread.sleep(forTimeInterval: 1)
            }
            throw HotspotFailure("未在验收窗口内确认热点、桥接地址与 DHCP 同时就绪。")
        } catch {
            let failure = error
            do {
                if guardProcess.isRunning {
                    try request("restore", session: session)
                    try waitForRecovery(session)
                } else { try recoverAndVerify(session) }
            }
                catch { fputs("共享恢复未完成：\(error)；备份在 \(session.path)\n", stderr) }
            throw failure
        }
    }

    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first ?? "preflight" {
            case "preflight" where args.count <= 1: try preflight()
            case "status" where args.count == 1:
                var state = try sharingState()
                state["sharing_enabled"] = HotspotPolicy.enabled(try currentNAT())
                try emit(state)
            case "enable" where args.count == 1: try enable()
            case "trial" where args.count == 1: try enable(trial: true)
            case "restore" where args.count == 2: try recoverAndVerify(URL(fileURLWithPath: args[1]))
            case "watchdog" where args.count == 2: try watchdog(URL(fileURLWithPath: args[1]))
            case "keep" where args.count == 2, "request-restore" where args.count == 2:
                try request(args[0] == "keep" ? "keep" : "restore", session: URL(fileURLWithPath: args[1]))
            case "detach-test" where args.count == 2, "detach-test-child" where args.count == 2:
                try detachTest(URL(fileURLWithPath: args[1]), child: args[0] == "detach-test-child")
            default: throw HotspotFailure("usage: magicbay-hotspotctl [preflight | status | trial | enable | keep SESSION | request-restore SESSION | restore SESSION]")
            }
        } catch {
            fputs("hotspot_error=\(error)\n", stderr)
            exit(1)
        }
    }
}

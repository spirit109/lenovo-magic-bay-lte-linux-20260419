import Foundation
import SystemConfiguration
import Darwin

struct ProxyCompatibilityFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

final class ProxyProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any] = [:]
    var value: [String: Any] {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

// A session-owned State:/.../Proxies value. configd removes it when this
// process exits, including an abnormal exit; another writer is never replaced.
@main struct ProxyCompatibilityMain {
    static let runner = CommandRunner()
    static let legacyService = "7E2F4BC0-4241-4C54-8B49-4D42494D4C54"

    struct Context {
        let service: String
        let process: ProcessIdentity
        let interface: String
        let port: Int
        let proxies: [String: Any]
        var key: String { "State:/Network/Service/\(service)/Proxies" }
    }

    static func makeStore(_ name: String) throws -> SCDynamicStore {
        guard let store = SCDynamicStoreCreate(nil, name as CFString, nil, nil) else {
            throw ProxyCompatibilityFailure("无法读取 macOS 网络状态。")
        }
        return store
    }

    static func dictionary(_ store: SCDynamicStore, _ key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    static func context(_ store: SCDynamicStore) throws -> Context {
        guard let global = dictionary(store, "State:/Network/Global/IPv4"),
              let service = global["PrimaryService"] as? String,
              [legacyService, RuntimePaths.dnsService].contains(service),
              let interface = global["PrimaryInterface"] as? String,
              interface.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil else {
            throw ProxyCompatibilityFailure("LTE 不是当前系统主要连接，未修改代理。")
        }
        let paths = service == legacyService ? RuntimePaths.legacy : RuntimePaths.current
        let inspector = MacInspector()
        let inventory = inspector.processes()
        let helpers = inventory.entries.filter { URL(fileURLWithPath: $0.executable).lastPathComponent == "mbim-net" }
        guard inventory.available, helpers.count == 1, let process = helpers.first, process.uid == 0,
              process.executable == paths.executable,
              let pid = inspector.readRegularFile(paths.pidFile), Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)) == process.pid,
              let ipv4 = dictionary(store, "State:/Network/Service/\(service)/IPv4"),
              ipv4["InterfaceName"] as? String == interface,
              let address = (ipv4["Addresses"] as? [String])?.first else {
            throw ProxyCompatibilityFailure("没有确认唯一、受管理的 LTE 后台。")
        }
        let iface = runner.run("/sbin/ifconfig", [interface], timeout: 3)
        guard iface.code == 0, Match.all(#"\binet ([0-9.]+)"#, iface.output).contains(address) else {
            throw ProxyCompatibilityFailure("LTE 接口地址与服务记录不一致。")
        }
        var console = stat()
        guard stat("/dev/console", &console) == 0, console.st_uid > 0,
              let user = getpwuid(console.st_uid) else { throw ProxyCompatibilityFailure("无法确认本机登录用户。") }
        let homeDirectory = String(cString: user.pointee.pw_dir)
        let plistPath = homeDirectory + "/Library/Preferences/com.follow.clash.plist"
        let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
        guard let prefs = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let json = prefs["flutter.config"] as? String,
              let config = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let network = config["networkProps"] as? [String: Any], network["systemProxy"] as? Bool == true,
              let patch = config["patchClashConfig"] as? [String: Any],
              let port = patch["mixed-port"] as? Int, (1...65535).contains(port) else {
            throw ProxyCompatibilityFailure("FlClash 没有开启系统代理，或代理端口不明确。")
        }
        guard let system = SCPreferencesCreate(nil, "MagicBayProxyReadOnly" as CFString, nil),
              let services = SCPreferencesGetValue(system, "NetworkServices" as CFString) as? [String: [String: Any]],
              let source = services.values.compactMap({ $0["Proxies"] as? [String: Any] }).first(where: {
                  ($0["HTTPEnable"] as? NSNumber)?.boolValue == true &&
                  ($0["HTTPSEnable"] as? NSNumber)?.boolValue == true &&
                  ($0["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue != true &&
                  $0["HTTPProxy"] as? String == "127.0.0.1" && $0["HTTPSProxy"] as? String == "127.0.0.1" &&
                  $0["HTTPPort"] as? Int == port && $0["HTTPSPort"] as? Int == port
              }) else { throw ProxyCompatibilityFailure("没有找到用户已有的 FlClash 系统代理设置。") }
        let keys = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
                    "SOCKSEnable", "SOCKSProxy", "SOCKSPort", "ExcludeSimpleHostnames"]
        var proxies = source.filter { keys.contains($0.key) }
        let exceptions = (source["ExceptionsList"] as? [String] ?? []).flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        proxies["ExceptionsList"] = Array(Set(exceptions + ["localhost", "*.local", "127.0.0.1", "::1"])).sorted()
        proxies["ExcludeSimpleHostnames"] = 1
        proxies["ProxyAutoConfigEnable"] = 0
        return Context(service: service, process: process, interface: interface, port: port, proxies: proxies)
    }

    static func emit(_ data: [String: Any]) throws {
        let output = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: output, as: UTF8.self))
        fflush(stdout)
    }

    static func probe(_ url: String, proxies: [String: Any]? = nil) -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = proxies
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 9
        let session = URLSession(configuration: configuration)
        let box = ProxyProbeBox()
        let done = DispatchSemaphore(value: 0)
        let began = Date()
        let task = session.dataTask(with: URL(string: url)!) { _, response, error in
            box.value = ["http": (response as? HTTPURLResponse)?.statusCode ?? 0,
                         "error_code": (error as NSError?)?.code ?? 0,
                         "seconds": Date().timeIntervalSince(began)]
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + 10)
        session.invalidateAndCancel()
        return box.value.isEmpty ? ["http": 0, "error_code": -1001, "seconds": 10] : box.value
    }

    static func runProbe() throws {
        let store = try makeStore("MagicBayProxyProbe")
        let current = try context(store)
        for explicit in [false, true] {
            var result = probe("https://chatgpt.com/robots.txt", proxies: explicit ? current.proxies : nil)
            result["mode"] = explicit ? "foundation_explicit_proxy" : "foundation_system_default"
            result["observed_at"] = ISO8601DateFormatter().string(from: Date())
            try emit(result)
        }
    }

    static func selfTest() throws {
        let reader = try makeStore("MagicBayTemporaryKeyReader")
        let key = "State:/MagicBayProxyCompatibilityTest/" + UUID().uuidString
        var owner: SCDynamicStore? = try makeStore("MagicBayTemporaryKeyOwner")
        guard SCDynamicStoreAddTemporaryValue(owner!, key as CFString, ["test": true] as CFDictionary),
              dictionary(reader, key) != nil else { throw ProxyCompatibilityFailure("临时键创建检查失败：\(SCError())") }
        withExtendedLifetime(owner) {}
        owner = nil
        for _ in 0..<30 {
            if dictionary(reader, key) == nil {
                try emit(["temporary_session_cleanup": "passed", "network_keys_changed": false])
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ProxyCompatibilityFailure("临时键未自动清理，禁止启用修复。")
    }

    static func trial(seconds: Int) throws {
        guard (10...180).contains(seconds) else { throw ProxyCompatibilityFailure("试用时间仅允许 10–180 秒。") }
        let reader = try makeStore("MagicBayProxyReader")
        let before = try context(reader)
        guard dictionary(reader, before.key) == nil else {
            throw ProxyCompatibilityFailure("LTE 服务已有代理状态，拒绝覆盖。")
        }
        let check = probe("https://chatgpt.com/robots.txt", proxies: before.proxies)
        guard check["http"] as? Int == 200 else { throw ProxyCompatibilityFailure("现有显式代理未通过检测，未修改系统。") }
        let fresh = try context(reader)
        guard fresh.process == before.process, fresh.service == before.service,
              NSDictionary(dictionary: fresh.proxies).isEqual(to: before.proxies) else {
            throw ProxyCompatibilityFailure("LTE 或 FlClash 配置已变化，未修改系统。")
        }
        var owner: SCDynamicStore? = try makeStore("MagicBayProxyCompatibility")
        guard SCDynamicStoreAddTemporaryValue(owner!, before.key as CFString, before.proxies as CFDictionary) else {
            throw ProxyCompatibilityFailure("无法建立临时 LTE 代理状态，可能需要系统管理员授权。SCError=\(SCError())")
        }
        try emit(["phase": "temporary_proxy_added", "pid": getpid(), "uid": getuid(),
                  "service": before.service, "interface": before.interface, "port": before.port,
                  "auto_restore_seconds": seconds, "backend_pid": before.process.pid])
        let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        while ProcessInfo.processInfo.systemUptime < deadline {
            let current = try? context(reader)
            guard current?.process == before.process, current?.service == before.service,
                  let proxies = current?.proxies, NSDictionary(dictionary: proxies).isEqual(to: before.proxies) else { break }
            let port = runner.run("/usr/bin/nc", ["-z", "-w", "1", "127.0.0.1", String(before.port)], timeout: 2)
            if port.code != 0 { break }
            Thread.sleep(forTimeInterval: 1)
        }
        withExtendedLifetime(owner) {}
        owner = nil
        for _ in 0..<30 {
            if dictionary(reader, before.key) == nil {
                try emit(["phase": "restored", "temporary_proxy_removed": true, "backend_changed": (try? context(reader).process) != before.process])
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ProxyCompatibilityFailure("代理状态已被其他会话接管或尚未清理，请重新核对。")
    }

    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            switch args.first ?? "check" {
            case "self-test" where args.count == 1: try selfTest()
            case "status" where args.count == 1:
                try emit(dictionary(try makeStore("MagicBayProxyStatus"), statusKey) ?? ["state": "stopped"])
            case "start" where args.count == 1: try startWatcher()
            case "stop" where args.count == 1: try stopWatcher()
            case "watch" where args.count == 1: try watch()
            case "probe" where args.count == 1: try runProbe()
            case "trial" where args.count == 2:
                guard let seconds = Int(args[1]) else { throw ProxyCompatibilityFailure("无效试用时间。") }
                try trial(seconds: seconds)
            case "check" where args.count <= 1:
                let reader = try makeStore("MagicBayProxyCheck")
                let current = try context(reader)
                try emit(["service": current.service, "interface": current.interface, "port": current.port,
                          "service_proxies_present": dictionary(reader, current.key) != nil,
                          "global_proxies": dictionary(reader, "State:/Network/Global/Proxies") ?? [:], "system_changes": false])
            default: throw ProxyCompatibilityFailure("usage: magicbay-proxy-compat [check | probe | self-test | trial SECONDS | status | start | stop]")
            }
        } catch { fputs("proxy_compatibility_error=\(error)\n", stderr); exit(1) }
    }
}

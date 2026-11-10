import Foundation
import SystemConfiguration
import Darwin

extension ProxyCompatibilityMain {
    static let statusKey = "State:/MagicBayLTEProxyCompatibility/Status"
    static var executableURL: URL { URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath() }

    static func ownedWatcher(_ status: [String: Any]) -> ProcessIdentity? {
        guard let pid = (status["pid"] as? NSNumber)?.int32Value,
              let started = status["started"] as? String, let path = status["executable"] as? String else { return nil }
        guard path == executableURL.path, path.hasSuffix("/magicbay-proxy-compat") else { return nil }
        return MacInspector().processes().entries.first { $0.pid == pid && $0.uid == 0 && $0.started == started && $0.executable == path }
    }

    static func startWatcher() throws {
        guard geteuid() == 0 else { throw ProxyCompatibilityFailure("启动兼容助手需要 macOS 管理员授权。") }
        let reader = try makeStore("MagicBayProxyStart")
        if let existing = dictionary(reader, statusKey) {
            guard ownedWatcher(existing) != nil else { throw ProxyCompatibilityFailure("已有无法核验的兼容助手记录，未启动新进程。") }
            try emit(existing)
            return
        }
        let directory = executableURL.path == "/usr/local/libexec/magic-bay-lte-v2/magicbay-proxy-compat"
            ? URL(fileURLWithPath: RuntimePaths.current.directory) : executableURL.deletingLastPathComponent()
        let log = directory.appendingPathComponent("proxy-watch-" + UUID().uuidString + ".log")
        let fd = open(log.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ProxyCompatibilityFailure("无法创建本地诊断日志。") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let input = FileHandle(forReadingAtPath: "/dev/null")!
        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["watch"]
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = output
        try child.run()
        try? output.close()
        try? input.close()
        for _ in 0..<50 {
            if let status = dictionary(reader, statusKey), ownedWatcher(status)?.pid == child.processIdentifier {
                try emit(status)
                return
            }
            if !child.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if child.isRunning { child.terminate() }
        throw ProxyCompatibilityFailure("兼容助手未确认启动，已停止本次创建的进程。")
    }

    static func stopWatcher() throws {
        guard geteuid() == 0 else { throw ProxyCompatibilityFailure("停止兼容助手需要 macOS 管理员授权。") }
        let reader = try makeStore("MagicBayProxyStop")
        guard let status = dictionary(reader, statusKey) else { try emit(["state": "stopped", "changed": false]); return }
        guard let process = ownedWatcher(status) else { throw ProxyCompatibilityFailure("进程身份不匹配，未终止任何进程。") }
        guard kill(process.pid, SIGTERM) == 0 else { throw ProxyCompatibilityFailure("无法请求兼容助手退出。") }
        for _ in 0..<50 {
            if dictionary(reader, statusKey) == nil {
                try emit(["state": "stopped", "session_closed": true,
                          "service_proxy_still_present": (status["service_key"] as? String).flatMap { dictionary(reader, $0) } != nil])
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ProxyCompatibilityFailure("兼容助手尚未退出，未强制终止。")
    }

    static func watch() throws {
        guard geteuid() == 0 else { throw ProxyCompatibilityFailure("兼容助手需要系统授权。") }
        signal(SIGHUP, SIG_IGN)
        _ = setsid()
        var console = stat()
        guard stat("/dev/console", &console) == 0, console.st_uid > 0,
              let identity = MacInspector().processes().entries.first(where: { $0.pid == getpid() }) else {
            throw ProxyCompatibilityFailure("无法核对兼容助手所属会话。")
        }
        let consoleUID = console.st_uid
        let statusOwner = try makeStore("MagicBayProxyWatchStatus")
        var status: [String: Any] = ["pid": getpid(), "started": identity.started, "executable": executableURL.path,
                                     "console_uid": consoleUID, "state": "starting"]
        guard SCDynamicStoreAddTemporaryValue(statusOwner, statusKey as CFString, status as CFDictionary) else {
            throw ProxyCompatibilityFailure("另一兼容助手已经运行，未重复接管。")
        }
        let reader = try makeStore("MagicBayProxyWatchReader")
        var owner: SCDynamicStore?
        var ownedContext: Context?
        var boundBackend: ProcessIdentity?
        var previousState = ""
        while stat("/dev/console", &console) == 0 && console.st_uid == consoleUID {
            do {
                let current = try context(reader)
                if let bound = boundBackend, current.process != bound {
                    owner = nil
                    ownedContext = nil
                    print("proxy_watch_stopped=backend_session_changed")
                    break
                }
                boundBackend = current.process
                if let old = ownedContext, old.service != current.service || old.process != current.process || !NSDictionary(dictionary: old.proxies).isEqual(to: current.proxies) {
                    owner = nil
                    ownedContext = nil
                }
                if owner == nil {
                    guard dictionary(reader, current.key) == nil else { throw ProxyCompatibilityFailure("LTE 已有其他代理状态，未覆盖。") }
                    let port = runner.run("/usr/bin/nc", ["-z", "-w", "1", "127.0.0.1", String(current.port)], timeout: 2)
                    guard port.code == 0 else { throw ProxyCompatibilityFailure("等待 FlClash 代理端口就绪。") }
                    let candidate = try makeStore("MagicBayProxyCompatibilityWatch")
                    guard SCDynamicStoreAddTemporaryValue(candidate, current.key as CFString, current.proxies as CFDictionary) else {
                        throw ProxyCompatibilityFailure("LTE 代理状态已被其他会话更新，未覆盖。")
                    }
                    owner = candidate
                    ownedContext = current
                }
                guard let actual = dictionary(reader, current.key), NSDictionary(dictionary: actual).isEqual(to: current.proxies) else {
                    throw ProxyCompatibilityFailure("LTE 代理状态已由其他会话改变，停止兼容接管。")
                }
                let global = dictionary(reader, "State:/Network/Global/Proxies") ?? [:]
                let effective = (global["HTTPSEnable"] as? NSNumber)?.boolValue == true &&
                    global["HTTPSProxy"] as? String == "127.0.0.1" && global["HTTPSPort"] as? Int == current.port
                status["state"] = effective ? "active" : "applying"
                status["message"] = effective ? "LTE 已继承 FlClash 系统代理。" : "等待系统应用 LTE 代理状态。"
                status["service_key"] = current.key
                status["port"] = current.port
                status["backend_pid"] = current.process.pid
            } catch {
                if let bound = boundBackend {
                    let inventory = MacInspector().processes()
                    if ConnectionPolicy.sessionPresent(bound, inventoryAvailable: inventory.available, entries: inventory.entries) == false {
                        owner = nil
                        ownedContext = nil
                        print("proxy_watch_stopped=backend_session_ended")
                        break
                    }
                }
                owner = nil
                ownedContext = nil
                status["state"] = "idle"
                status["message"] = String(describing: error)
                status["service_key"] = nil
                status["backend_pid"] = nil
            }
            status["updated_at"] = ISO8601DateFormatter().string(from: Date())
            guard SCDynamicStoreSetValue(statusOwner, statusKey as CFString, status as CFDictionary) else { break }
            let state = (status["state"] as? String ?? "") + (status["message"] as? String ?? "")
            if state != previousState { try emit(status); previousState = state }
            withExtendedLifetime(owner) { Thread.sleep(forTimeInterval: 2) }
        }
        withExtendedLifetime(owner) {}
        withExtendedLifetime(statusOwner) {}
    }
}

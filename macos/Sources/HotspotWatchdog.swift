import Foundation
import SystemConfiguration
import Darwin

extension HotspotMain {
    static var executableURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    }

    static func atomicRecord(_ value: [String: Any], at url: URL, mode: Int = 0o600) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    static func detach(_ arguments: [String], log: URL) throws -> Process {
        let fd = open(log.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HotspotFailure("无法创建独立守护日志。") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let input = FileHandle(forReadingAtPath: "/dev/null")!
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try? input.close()
        try? output.close()
        return process
    }

    static func savedUpstream(_ session: URL) throws -> HotspotUpstream {
        let record = try dictionary(at: session.appendingPathComponent("upstream.plist").path)
        return try JSONDecoder().decode(HotspotUpstream.self, from: JSONSerialization.data(withJSONObject: record))
    }

    static func controlDirectory(_ session: URL) -> URL {
        session.deletingLastPathComponent().appendingPathComponent("control-" + session.lastPathComponent)
    }

    static func statusRecord(_ session: URL, _ state: String, _ message: String,
                             extra: [String: Any] = [:]) throws {
        var data = extra
        data["state"] = state
        data["message"] = message
        data["updated_at"] = ISO8601DateFormatter().string(from: Date())
        data["guard_pid"] = getpid()
        try atomicRecord(data, at: controlDirectory(session).appendingPathComponent("status.plist"), mode: 0o644)
    }

    static func startGuard(_ session: URL) throws -> Process {
        var console = stat()
        guard stat("/dev/console", &console) == 0, console.st_uid > 0 else {
            throw HotspotFailure("无法确认已登录用户，未启用热点。")
        }
        let control = controlDirectory(session)
        try fm.createDirectory(at: control, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        guard chown(control.path, console.st_uid, console.st_gid) == 0 else {
            throw HotspotFailure("无法准备用户可点击的恢复通道。")
        }
        let child = try detach(["watchdog", session.path], log: session.appendingPathComponent("watchdog.log"))
        for _ in 0..<50 {
            if let ready = try? dictionary(at: session.appendingPathComponent("guard-ready.plist").path),
               (ready["pid"] as? NSNumber)?.int32Value == child.processIdentifier, child.isRunning {
                let pointer: [String: Any] = ["session": session.path, "control": control.path,
                                               "guard_pid": child.processIdentifier, "tool": executableURL.path]
                try atomicRecord(pointer, at: executableURL.deletingLastPathComponent().appendingPathComponent("current-session.plist"), mode: 0o644)
                print("independent_guard_pid=\(child.processIdentifier) auto_restore_seconds=120")
                fflush(stdout)
                return child
            }
            guard child.isRunning else { throw HotspotFailure("独立回退守护未成功启动，未修改共享。") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw HotspotFailure("回退守护没有确认就绪，未修改共享。")
    }

    static func health(_ expected: HotspotUpstream) -> Bool {
        guard (try? upstream()) == expected else { return false }
        let direct = MacInspector().probe(name: "Apple", url: "https://www.apple.com/library/test/success.html", interface: expected.interface)
        let system = MacInspector().systemProbe()
        return direct.outcome == .passed && system.outcome == .passed && (try? upstream()) == expected
    }

    static func recoverAndVerify(_ session: URL) throws {
        let expected = try savedUpstream(session)
        try restore(session)
        // Sharing normally leaves the LTE route in place. If there is no
        // default route after teardown, restore only this verified, live MBIM
        // gateway. An unrelated selected route is never overwritten.
        let route = runner.run("/sbin/route", ["-n", "get", "default"], timeout: 4)
        if route.code != 0 {
            let inventory = MacInspector().processes()
            let same = inventory.available && inventory.entries.contains {
                $0.pid == expected.pid && $0.uid == 0 && $0.started == expected.started && $0.executable == expected.executable
            }
            let iface = runner.run("/sbin/ifconfig", [expected.interface], timeout: 4)
            if same && iface.code == 0 && Match.all(#"\binet ([0-9.]+)"#, iface.output).contains(expected.address) {
                let repaired = runner.run("/sbin/route", ["-n", "add", "default", expected.gateway], timeout: 5)
                guard repaired.code == 0 else { throw HotspotFailure("热点已关闭，但默认路由恢复未成功。") }
            }
        }
        for _ in 0..<3 {
            if health(expected) {
                try statusRecord(session, "restored", "热点已关闭，原 LTE 连接与系统 HTTPS 访问已恢复。",
                                 extra: ["lte_verified": true, "system_access_verified": true])
                print("rollback_verified=1 lte_and_system_https=passed")
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        throw HotspotFailure("原共享配置已恢复，但互联网访问复核未通过；恢复入口仍保留。")
    }

    static func watchdog(_ session: URL) throws {
        guard geteuid() == 0 else { throw HotspotFailure("回退守护需要管理员权限。") }
        signal(SIGHUP, SIG_IGN)
        _ = setsid()
        let original = try dictionary(at: session.appendingPathComponent("original-nat.plist").path)
        let applied = try dictionary(at: session.appendingPathComponent("applied-nat.plist").path)
        let expected = try savedUpstream(session)
        let control = controlDirectory(session)
        let started = ProcessInfo.processInfo.systemUptime
        try statusRecord(session, "armed", "本机独立回退守护已就绪，正在等待热点启动。")
        try save(["pid": getpid(), "ppid": getppid(), "armed": true], name: "guard-ready.plist", in: session)
        var confirmed = false
        var activated = false
        var failures = 0
        var nextCheck = started + 10
        do {
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - started
                let current = try currentNAT()
                if HotspotPolicy.sameConfiguration(current, applied) { activated = true }
                if activated && HotspotPolicy.sameConfiguration(current, original) {
                    try recoverAndVerify(session)
                    return
                }
                let ready = fm.fileExists(atPath: session.appendingPathComponent("activation-ready.plist").path)
                let requested = fm.fileExists(atPath: control.appendingPathComponent("restore.request").path)
                if ready && !confirmed && fm.fileExists(atPath: control.appendingPathComponent("keep.request").path) && health(expected) {
                    confirmed = true
                }
                if activated && now >= nextCheck {
                    failures = health(expected) ? 0 : failures + 1
                    nextCheck = ProcessInfo.processInfo.systemUptime + 10
                }
                let decision = HotspotGuardPolicy.decide(elapsed: elapsed, confirmed: confirmed, activationReady: ready,
                                                         restoreRequested: requested, failures: failures)
                if decision == .restore {
                    let reason = requested ? "收到恢复请求" : (failures >= 2 ? "连续联网复核失败" : "未确认保留，试用时间到期")
                    try statusRecord(session, "restoring", "\(reason)，正在自动关闭热点并恢复原共享设置。")
                    try recoverAndVerify(session)
                    return
                }
                let label = confirmed ? "monitoring" : (ready ? "awaiting_confirmation" : "armed")
                try statusRecord(session, label, confirmed ? "热点已确认保留，本机回退守护持续运行。" : "热点试用中，未确认保留会自动恢复。",
                                 extra: ["seconds_until_auto_restore": max(0, Int(120 - elapsed)), "confirmed": confirmed,
                                         "consecutive_health_failures": failures])
                Thread.sleep(forTimeInterval: 0.5)
            }
        } catch {
            let first = error
            do { try recoverAndVerify(session) }
            catch {
                try? statusRecord(session, "blocked", "自动恢复未通过：\(error)。请双击桌面恢复入口再次执行本机恢复。")
                throw first
            }
        }
    }

    static func waitForRecovery(_ session: URL, seconds: TimeInterval = 55) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let status = try? dictionary(at: controlDirectory(session).appendingPathComponent("status.plist").path),
               let state = status["state"] as? String {
                if state == "restored" { print("independent_rollback_verified=1"); return }
                if state == "blocked" { throw HotspotFailure(status["message"] as? String ?? "自动恢复失败。") }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw HotspotFailure("等待独立回退结果超时；请使用桌面恢复入口。")
    }

    static func request(_ action: String, session: URL) throws {
        guard ["restore", "keep"].contains(action) else { throw HotspotFailure("无效恢复请求。") }
        let target = controlDirectory(session).appendingPathComponent(action + ".request")
        if !fm.fileExists(atPath: target.path) { try Data().write(to: target, options: .withoutOverwriting) }
        print("\(action)_requested=1")
    }

    // A real detached-child survival check on project-local files only. Uses
    // the same process launch path as the privileged watchdog, with no network.
    static func detachTest(_ directory: URL, child: Bool) throws {
        if child {
            signal(SIGHUP, SIG_IGN)
            _ = setsid()
            try atomicRecord(["pid": getpid(), "ppid": getppid()], at: directory.appendingPathComponent("ready.plist"))
            Thread.sleep(forTimeInterval: 3)
            try atomicRecord(["pid": getpid(), "ppid": getppid(), "survived": true], at: directory.appendingPathComponent("survived.plist"))
        } else {
            let process = try detach(["detach-test-child", directory.path], log: directory.appendingPathComponent("child.log"))
            for _ in 0..<30 {
                if fm.fileExists(atPath: directory.appendingPathComponent("ready.plist").path) {
                    print("detached_test_pid=\(process.processIdentifier)")
                    return
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw HotspotFailure("离线守护进程启动检查未通过。")
        }
    }
}

import Foundation
import Darwin
import SystemConfiguration

struct ControllerFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

@main struct RootController {
    static let runner = CommandRunner()
    static let inspector = MacInspector()

    static func main() {
        do { try execute(Array(CommandLine.arguments.dropFirst())) }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }

    static func execute(_ arguments: [String]) throws {
        guard let action = arguments.first else { throw ControllerFailure("usage: rootctl permissions | version | status | start APN | repair | stop | recover-home") }
        if action == "version", arguments.count == 1 { print("version=2 app_version=\(AppRelease.version)"); return }
        if action == "status", arguments.count == 1 { print(diagnostics(snapshot: inspector.collect(), evidence: nil)); return }
        guard geteuid() == 0 else { throw ControllerFailure("administrator_required") }
        if action == "permissions", arguments.count == 1 { print("authorized=1 version=2"); return }
        guard (action == "start" && arguments.count == 2) || (["repair", "stop", "recover-home"].contains(action) && arguments.count == 1) else { throw ControllerFailure("invalid_arguments") }
        let apn = arguments.count == 2 ? arguments[1] : "3gnet"
        if action == "start" && !ConnectionPolicy.validAPN(apn) { throw ControllerFailure("invalid APN") }

        try prepareDirectory(RuntimePaths.current.directory)
        let lock = open(RuntimePaths.current.directory + "/control.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ControllerFailure("cannot_open_control_lock") }
        defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ControllerFailure("operation_in_progress: 请等待当前操作结束。") }
        defer { flock(lock, LOCK_UN) }

        let snapshot = inspector.collect()
        if action == "recover-home" { try recoverHome(snapshot); return }
        switch ControllerPolicy.decide(action: action, apn: apn, snapshot: snapshot) {
        case .refuse(let reason): throw ControllerFailure(reason)
        case .alreadyRunning: manageProxy("start"); print("running=1 pid=\(snapshot.process!.pid) changed=0 needs_connectivity_check=1")
        case .alreadyStopped: manageProxy("stop"); print("running=0 changed=0")
        case .startNew: try start(apn: apn)
        case .restart: try restart(snapshot, apn: apn)
        case .stop: try stop(snapshot.process!); manageProxy("stop")
        case .repair: try repair(snapshot)
        }
    }

    static func prepareDirectory(_ path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0, info.st_mode & 0o022 == 0 else { throw ControllerFailure("unsafe_runtime_directory") }
    }

    static func recycleRuntimeFile(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0 else { throw ControllerFailure("unsafe_runtime_file") }
        let recycle = RuntimePaths.current.directory + "/_RecycleBin"
        try prepareDirectory(recycle)
        let destination = recycle + "/" + URL(fileURLWithPath: path).lastPathComponent + "-" + UUID().uuidString
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        print("archived_runtime=\(destination)")
    }

    static func sameProcess(_ process: ProcessIdentity) -> Bool {
        inspector.processes().entries.contains(process)
    }

    static func start(apn: String) throws {
        var info = stat()
        guard lstat(RuntimePaths.current.executable, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0 else { throw ControllerFailure("unsafe_or_missing_backend") }
        try recycleRuntimeFile(RuntimePaths.current.pidFile)
        try recycleRuntimeFile(RuntimePaths.current.logFile)
        let started = runner.run(RuntimePaths.current.executable, ["--daemonize", "--pid-file=" + RuntimePaths.current.pidFile,
            "--log-file=" + RuntimePaths.current.logFile, "--takeover-default", "--restore-on-exit", "--apn=" + apn, "--ip-type=ipv4"], timeout: 8)
        guard started.code == 0, let pid = Int32(started.output.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { throw ControllerFailure("start_failed: " + started.output) }
        for _ in 0..<45 {
            let processes = inspector.processes()
            guard processes.available else { throw ControllerFailure("process_inventory_unavailable") }
            guard processes.entries.contains(where: { $0.pid == pid && $0.uid == 0 && $0.executable == RuntimePaths.current.executable }) else {
                let log = inspector.readRegularFile(RuntimePaths.current.logFile) ?? ""
                var failed = ConnectionSnapshot()
                ConnectionPolicy.parseLog(log, into: &failed)
                throw ControllerFailure("start_failed: " + (failed.error ?? "后台已退出，请检查设备与 SIM 卡。"))
            }
            let log = inspector.readRegularFile(RuntimePaths.current.logFile) ?? ""
            if log.contains("MBIM_NET ready=1") {
                let state = inspector.collect()
                guard state.process?.pid == pid, state.routeMatches, state.takeoverReady else { throw ControllerFailure("start_route_verification_failed") }
                manageProxy("start")
                print("running=1 pid=\(pid) ready=1 needs_connectivity_check=1")
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        // A slow connection is not restarted or killed. The UI keeps observing it.
        throw ControllerFailure("startup_timeout pid=\(pid)")
    }

    static func stop(_ process: ProcessIdentity) throws {
        guard sameProcess(process) else { throw ControllerFailure("process_identity_changed") }
        guard Darwin.kill(process.pid, SIGTERM) == 0 else { throw ControllerFailure("stop_signal_failed") }
        for _ in 0..<30 {
            let inventory = inspector.processes()
            guard inventory.available else { throw ControllerFailure("process_inventory_unavailable") }
            if !inventory.entries.contains(process) { print("running=0 stopped_pid=\(process.pid)"); return }
            Thread.sleep(forTimeInterval: 1)
        }
        throw ControllerFailure("stop_timeout pid=\(process.pid)")
    }

    static func restart(_ snapshot: ConnectionSnapshot, apn: String) throws {
        guard let process = snapshot.process, snapshot.backendInterrupted,
              snapshot.devicePresent == true, process.executable == RuntimePaths.current.executable,
              sameProcess(process) else { throw ControllerFailure("recovery_state_changed") }
        try stop(process)
        manageProxy("stop")
        let current = inspector.collect()
        guard current.devicePresent == true,
              ControllerPolicy.decide(action: "start", apn: apn, snapshot: current) == .startNew else {
            throw ControllerFailure("recovery_state_changed: 旧连接已释放，当前设备需重新检测。")
        }
        try start(apn: apn)
    }

    static func repair(_ snapshot: ConnectionSnapshot) throws {
        guard let process = snapshot.process, sameProcess(process), let interface = snapshot.interface,
              let gateway = snapshot.gateway, ipv4(gateway), let address = snapshot.address,
              let ip = address.split(separator: "/").first.map(String.init), ipv4(ip),
              snapshot.dns.allSatisfy(ipv4) else { throw ControllerFailure("invalid_repair_evidence") }
        if !snapshot.routeMatches {
            let result = runner.run("/sbin/route", ["-n", snapshot.defaultInterface == nil ? "add" : "change", "default", gateway], timeout: 6)
            guard result.code == 0 else { throw ControllerFailure("route_repair_failed: " + result.output) }
        }
        let route = runner.run("/sbin/route", ["-n", "get", "default"], timeout: 4)
        guard sameProcess(process), Match.last(#"interface:\s*(\S+)"#, route.output) == interface else { throw ControllerFailure("route_repair_not_verified") }
        if !snapshot.dns.isEmpty {
            let service = snapshot.runtime?.directory == RuntimePaths.current.directory ? RuntimePaths.dnsService : "7E2F4BC0-4241-4C54-8B49-4D42494D4C54"
            guard let store = SCDynamicStoreCreate(nil, "MagicBayLTE2" as CFString, nil, nil) else { throw ControllerFailure("dns_store_unavailable") }
            let dns: [String: Any] = ["ServerAddresses": snapshot.dns, "InterfaceName": interface, "SupplementalMatchDomains": [""]]
            guard SCDynamicStoreSetValue(store, "State:/Network/Service/\(service)/DNS" as CFString, dns as CFDictionary) else { throw ControllerFailure("dns_repair_failed") }
        }
        print("repair_verified=1 interface=\(interface) needs_connectivity_check=1")
    }

    static func manageProxy(_ action: String) {
        let path = "/usr/local/libexec/magic-bay-lte-v2/magicbay-proxy-compat"
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0 else { print("proxy_warning=companion_missing_or_untrusted"); return }
        let result = runner.run(path, [action], timeout: 8)
        if result.code != 0 { print("proxy_warning=companion_action_failed action=\(action)") }
    }

    static func recoverHome(_ snapshot: ConnectionSnapshot) throws {
        guard snapshot.helperCount <= 1, snapshot.helperCount == 0 || snapshot.process != nil else {
            throw ControllerFailure("unverified_backend: 未终止未知联网后台。")
        }
        if let process = snapshot.process { try stop(process) }
        manageProxy("stop")
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let wifi = interfaces.filter { SCNetworkInterfaceGetInterfaceType($0) as String? == kSCNetworkInterfaceTypeIEEE80211 as String }
        var name = wifi.count == 1 ? (SCNetworkInterfaceGetBSDName(wifi[0]) as String? ?? "") : ""
        var gateway: String?
        let metadata = "/usr/local/libexec/magic-bay-lte-v2/home-recovery.json"
        if let text = inspector.readRegularFile(metadata),
           let data = text.data(using: .utf8), let values = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            name = values["interface"] ?? name
            gateway = values["gateway"]
        }
        guard name.range(of: #"^en[0-9]+$"#, options: .regularExpression) != nil,
              wifi.contains(where: { SCNetworkInterfaceGetBSDName($0) as String? == name }),
              gateway == nil || ipv4(gateway!) else { throw ControllerFailure("home_wifi_identity_unavailable") }
        func homeRoute() -> Bool {
            let route = runner.run("/sbin/route", ["-n", "get", "default"], timeout: 3)
            return route.code == 0 && Match.last(#"interface:\s*(\S+)"#, route.output) == name &&
                (gateway == nil || Match.last(#"gateway:\s*(\S+)"#, route.output) == gateway)
        }
        if homeRoute() { print("home_recovered=1 interface=\(name) changed=0"); return }
        let power = runner.run("/usr/sbin/networksetup", ["-setairportpower", name, "on"], timeout: 8)
        guard power.code == 0 else { throw ControllerFailure("wifi_power_on_failed") }
        for _ in 0..<20 {
            if homeRoute() { print("home_recovered=1 interface=\(name) changed=1"); return }
            Thread.sleep(forTimeInterval: 1)
        }
        throw ControllerFailure("Wi-Fi 已开启；请在 Wi-Fi 菜单选择家里已保存的网络。未修改密码或 VPN。")
    }

    static func ipv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }
}

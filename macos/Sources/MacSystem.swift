import Foundation
import Darwin

struct CommandResult {
    var code: Int32
    var output: String
    var timedOut = false
}

protocol CommandExecuting {
    func run(_ executable: String, _ arguments: [String], timeout: Double) -> CommandResult
}

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk); if data.count > 262144 { data.removeFirst(data.count - 262144) } }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

struct CommandRunner: CommandExecuting {
    func run(_ executable: String, _ arguments: [String], timeout: Double = 8) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let pipe = Pipe()
        let buffer = OutputBuffer()
        process.standardOutput = pipe
        process.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                drained.signal()
            }
            if done.wait(timeout: .now() + timeout) == .timedOut {
                // Only this exact child, never a modem daemon or any pre-existing process.
                if process.isRunning { process.terminate() }
                _ = done.wait(timeout: .now() + 1)
                return CommandResult(code: 124, output: buffer.text + "\ncommand_timeout", timedOut: true)
            }
            _ = drained.wait(timeout: .now() + 1)
            return CommandResult(code: process.terminationStatus, output: buffer.text)
        } catch {
            return CommandResult(code: 127, output: error.localizedDescription)
        }
    }
}

struct MacInspector {
    var runner: any CommandExecuting = CommandRunner()

    func processes() -> (available: Bool, entries: [ProcessIdentity]) {
        let result = runner.run("/bin/ps", ["-axo", "pid=,uid=,lstart=,comm="], timeout: 5)
        guard result.code == 0 else { return (false, []) }
        let entries = result.output.split(separator: "\n").compactMap { line -> ProcessIdentity? in
            let parts = line.split(maxSplits: 7, whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count == 8, let pid = Int32(parts[0]), let uid = Int(parts[1]) else { return nil }
            return ProcessIdentity(pid: pid, uid: uid, started: parts[2..<7].joined(separator: " "), executable: parts[7].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (true, entries)
    }

    func readRegularFile(_ path: String, maxBytes: Int = 131072, requireRoot: Bool = true) -> String? {
        guard maxBytes > 0 else { return nil }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              !requireRoot || (info.st_uid == 0 && info.st_mode & 0o022 == 0) else { return nil }
        do {
            if info.st_size <= maxBytes {
                return String(decoding: try handle.read(upToCount: maxBytes) ?? Data(), as: UTF8.self)
            }
            // Startup identity and interface are at the beginning; recent
            // shutdown/error events are at the end. Keep both with a bound.
            let headLimit = min(65536, maxBytes / 2)
            let tailLimit = maxBytes - headLimit
            let head = try handle.read(upToCount: headLimit) ?? Data()
            try handle.seek(toOffset: UInt64(info.st_size - Int64(tailLimit)))
            let tail = try handle.read(upToCount: tailLimit) ?? Data()
            let prefix = head.lastIndex(of: 10).map { head.prefix(through: $0) } ?? Data.SubSequence()
            let suffix = tail.firstIndex(of: 10).map { tail.suffix(from: tail.index(after: $0)) } ?? Data.SubSequence()
            return String(decoding: prefix, as: UTF8.self) + "\n[bounded log gap]\n" + String(decoding: suffix, as: UTF8.self)
        } catch { return nil }
    }

    func collect(excludingAppPID: Int32 = getpid()) -> ConnectionSnapshot {
        var snapshot = ConnectionSnapshot()
        let inventory = processes()
        snapshot.evidenceAvailable = inventory.available
        guard inventory.available else { snapshot.error = "无法读取进程状态，已暂停控制操作。"; return snapshot }
        snapshot.competingApplications = inventory.entries.filter {
            $0.pid != excludingAppPID && ConnectionPolicy.isDesktopApplication($0.executable)
        }
        let helpers = inventory.entries.filter { URL(fileURLWithPath: $0.executable).lastPathComponent == "mbim-net" }
        let probes = inventory.entries.filter { Self.isModemProbe($0.executable) }
        snapshot.helperCount = helpers.count + probes.count
        if !probes.isEmpty { snapshot.competingApplications += probes }

        for paths in [RuntimePaths.current, .legacy] {
            guard let rawPID = readRegularFile(paths.pidFile), let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let process = helpers.first(where: { $0.pid == pid && $0.uid == 0 && $0.executable == paths.executable }) else { continue }
            snapshot.process = process
            snapshot.runtime = paths
            if let log = readRegularFile(paths.logFile), logBelongsToProcess(paths.logFile, process: process) {
                ConnectionPolicy.parseLog(log, into: &snapshot)
            } else { snapshot.error = "后台仍在运行，但没有可确认属于本次连接的日志。" }
            break
        }
        if snapshot.process == nil, let legacy = helpers.first(where: { $0.uid == 0 && ConnectionPolicy.isLegacyBundleHelper($0.executable) }) {
            snapshot.process = legacy
            snapshot.error = "检测到旧版临时授权连接，未读取其临时日志。请在可断网时通过旧版关闭连接，再使用新版连接。"
        }
        if snapshot.process == nil && !helpers.isEmpty {
            snapshot.competingApplications += helpers
            snapshot.error = "存在未识别的联网进程，已暂停启动，避免争用设备。"
        }
        if let process = snapshot.process, let started = Self.startDate(process.started) { snapshot.processAge = Date().timeIntervalSince(started) }
        if let interface = snapshot.interface {
            let info = runner.run("/sbin/ifconfig", [interface], timeout: 4)
            let ip = snapshot.address?.split(separator: "/").first.map(String.init)
            snapshot.interfacePresent = info.code == 0 && ip != nil && Match.all(#"\binet ([0-9.]+)"#, info.output).contains(ip!)
            let traffic = runner.run("/usr/sbin/netstat", ["-ibn", "-I", interface], timeout: 4)
            let counters = Self.parseCounters(traffic.output, interface: interface)
            snapshot.rxBytes = counters?.0
            snapshot.txBytes = counters?.1
        }
        let route = runner.run("/sbin/route", ["-n", "get", "default"], timeout: 4)
        snapshot.defaultInterface = Match.last(#"interface:\s*(\S+)"#, route.output)
        snapshot.defaultGateway = Match.last(#"gateway:\s*(\S+)"#, route.output)
        snapshot.dnsFingerprint = runner.run("/usr/sbin/scutil", ["--dns"], timeout: 4).output
        let proxy = runner.run("/usr/sbin/scutil", ["--proxy"], timeout: 4)
        snapshot.proxyFingerprint = proxy.output
        if proxy.output.contains("ProxyAutoConfigEnable : 1") { snapshot.proxySummary = "系统自动代理（PAC）" }
        else if proxy.output.contains("HTTPSEnable : 1") || proxy.output.contains("SOCKSEnable : 1") { snapshot.proxySummary = "系统代理已启用" }
        let routes = runner.run("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeout: 4)
        snapshot.otherTunnelRoutes = routes.output.split(separator: "\n").contains { line in
            line.contains("utun") && !line.contains(snapshot.interface ?? "<no-lte>")
        }
        // A surviving PID must not hide a removed or newly reinserted device.
        snapshot.devicePresent = usbDevicePresent()
        snapshot.authorization = FileManager.default.isExecutableFile(atPath: RuntimePaths.controller) ? .unknown : .missing
        return snapshot
    }

    func logBelongsToProcess(_ path: String, process: ProcessIdentity) -> Bool {
        guard let started = Self.startDate(process.started),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return modified.timeIntervalSince(started) >= -2
    }

    static func isModemProbe(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasPrefix("mbim-probe") || name == "magic-bay-device-info"
    }

    static func startDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: text)
    }

    func usbDevicePresent() -> Bool? {
        let result = runner.run("/usr/sbin/ioreg", ["-a", "-r", "-c", "IOUSBHostDevice"], timeout: 5)
        guard result.code == 0, let data = result.output.data(using: .utf8),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        func containsDevice(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                if (dictionary["idVendor"] as? NSNumber)?.intValue == 0x17ef && (dictionary["idProduct"] as? NSNumber)?.intValue == 0x7240 { return true }
                return dictionary.values.contains(where: containsDevice)
            }
            if let array = value as? [Any] { return array.contains(where: containsDevice) }
            return false
        }
        return containsDevice(value)
    }

    func authorization() -> AuthorizationState {
        guard FileManager.default.isExecutableFile(atPath: RuntimePaths.controller) else { return .missing }
        let result = runner.run("/usr/bin/sudo", ["-n", RuntimePaths.controller, "permissions"], timeout: 5)
        guard result.code == 0 && result.output.contains("authorized=1 version=2") else { return .denied }
        let version = runner.run(RuntimePaths.controller, ["version"], timeout: 3)
        guard version.code == 0, let installed = Match.last(#"app_version=([0-9.]+)"#, version.output) else { return .unknown }
        return installed == AppRelease.version ? .ready : .outdated
    }

    static func parseCounters(_ output: String, interface: String) -> (Int64, Int64)? {
        let rows = output.split(separator: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        guard let header = rows.first, let rx = header.firstIndex(of: "Ibytes"), let tx = header.firstIndex(of: "Obytes"),
              let row = rows.dropFirst().first(where: { $0.first == interface && $0.contains(where: { $0.hasPrefix("<Link#") }) }) else { return nil }
        // utun has no link-layer Address token; physical interfaces may include one.
        let offset = row.count == header.count - 1 ? 1 : 0
        guard row.count > max(rx, tx) - offset, let receive = Int64(row[rx - offset]), let transmit = Int64(row[tx - offset]) else { return nil }
        return (receive, transmit)
    }

    func verify(_ snapshot: ConnectionSnapshot) -> ConnectivityEvidence {
        guard snapshot.running, !snapshot.backendInterrupted, snapshot.interfacePresent, let interface = snapshot.interface else {
            return ConnectivityEvidence(fingerprint: snapshot.fingerprint, checkedAt: Date(), direct: [], system: ProbeCheck(name: "系统访问", outcome: .unknown, detail: "LTE 尚未就绪"))
        }
        let urls = [("Apple", "https://www.apple.com/library/test/success.html"), ("百度", "https://www.baidu.com/")]
        let direct = urls.map { name, url in probe(name: name, url: url, interface: interface) }
        let system = systemProbe()
        return ConnectivityEvidence(fingerprint: snapshot.fingerprint, checkedAt: Date(), direct: direct, system: system)
    }

    func probe(name: String, url: String, interface: String) -> ProbeCheck {
        let result = runner.run("/usr/bin/curl", ["--disable", "--ipv4", "--silent", "--show-error", "--noproxy", "*", "--proxy", "", "--interface", "if!" + interface,
             "--connect-timeout", "4", "--max-time", "8", "--max-filesize", "65536", "--output", "/dev/null", "--write-out", "\nprobe_code=%{http_code} elapsed=%{time_total} dns_time=%{time_namelookup} connect_time=%{time_connect}", url], timeout: 10)
        let status = Match.last(#"probe_code=(\d+)"#, result.output).flatMap(Int.init) ?? 0
        let passed = result.code == 0 && (200..<400).contains(status)
        let reason: String
        if passed { reason = "HTTPS \(status) · 经 \(interface)" }
        else if result.code == 6 { reason = "域名解析失败" }
        else if result.code == 28 || result.timedOut {
            let dnsTime = Match.last(#"dns_time=([0-9.]+)"#, result.output).flatMap(Double.init) ?? 0
            reason = dnsTime == 0 ? "域名解析超时；暂未确认可达" : "连接超时；暂未确认可达"
        }
        else if result.code == 45 { reason = "LTE 接口已变化，请重新检测" }
        else { reason = "未通过（curl \(result.code)，HTTP \(status)）" }
        return ProbeCheck(name: name, outcome: passed ? .passed : .failed, detail: reason, elapsed: Match.last(#"elapsed=([0-9.]+)"#, result.output).flatMap(Double.init) ?? 0)
    }

    func systemProbe() -> ProbeCheck {
        // URLSession follows macOS proxy/PAC policy. This is deliberately separate
        // from curl's interface-bound direct check and does not change settings.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let done = DispatchSemaphore(value: 0)
        let box = ProbeResultBox()
        var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            box.value = ProbeCheck(name: "系统访问", outcome: error == nil && (200..<400).contains(status) ? .passed : .failed,
                                  detail: error == nil ? "系统网络策略 · HTTPS \(status)" : "系统路径未通过：\(error!.localizedDescription)")
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + 11)
        session.invalidateAndCancel()
        return box.value ?? ProbeCheck(name: "系统访问", outcome: .unknown, detail: "检测超时")
    }
}

final class ProbeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProbeCheck?
    var value: ProbeCheck? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

func diagnostics(snapshot: ConnectionSnapshot, evidence: ConnectivityEvidence?) -> String {
    var lines = ["Magic Bay LTE 2 · \(AppRelease.version)", "observed_at=\(ISO8601DateFormatter().string(from: snapshot.observedAt))",
                 "read_only=\(snapshot.readOnly)", "helper_count=\(snapshot.helperCount)", "pid=\(snapshot.process?.pid ?? 0)",
                 "process_started=\(snapshot.process?.started ?? "-")", "interface=\(snapshot.interface ?? "-")", "interface_verified=\(snapshot.interfacePresent)",
                 "default_interface=\(snapshot.defaultInterface ?? "-")", "dns_count=\(snapshot.dns.count)", "authorization=\(snapshot.authorization.rawValue)",
                 "system_proxy=\(snapshot.proxySummary)", "other_tunnel_routes=\(snapshot.otherTunnelRoutes)"]
    if let hardware = snapshot.hardwareModel { lines.append("hardware=\(hardware)") }
    if let firmware = snapshot.firmwareVersion { lines.append("firmware=\(firmware)") }
    if let quality = snapshot.liveSignalQuality {
        lines.append("live_signal_observed_at=\(ISO8601DateFormatter().string(from: quality.observedAt))")
        lines.append("live_signal_quality=\(quality.summary)")
    }
    if let evidence {
        lines.append("connectivity_fresh=\(evidence.isFresh(for: snapshot)) checked_at=\(ISO8601DateFormatter().string(from: evidence.checkedAt))")
        lines += (evidence.direct + [evidence.system]).map { "\($0.name): \($0.outcome.rawValue) \($0.detail)" }
    }
    if let error = snapshot.error { lines.append("last_error=\(ConnectionPolicy.readableError(error))") }
    return lines.joined(separator: "\n")
}

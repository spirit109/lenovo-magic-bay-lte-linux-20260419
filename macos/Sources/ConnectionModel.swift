import Foundation

enum AppRelease { static let version = "0.2.6" }

enum ConnectionPhase: String {
    case checking, noDevice, disconnected, starting, incomplete, routeMismatch, verifying, online, limited, stopping, conflict

    var title: String {
        switch self {
        case .checking: return "正在读取连接"
        case .noDevice: return "请连接 Magic Bay LTE"
        case .disconnected: return "LTE 尚未连接"
        case .starting: return "正在建立 LTE 连接"
        case .incomplete: return "LTE 连接未完成"
        case .routeMismatch: return "LTE 在线，系统使用其他路径"
        case .verifying: return "LTE 已连接，正在验证上网"
        case .online: return "LTE 可以上网"
        case .limited: return "LTE 已连接，上网检测未通过"
        case .stopping: return "正在断开 LTE"
        case .conflict: return "检测到多个联网后台"
        }
    }
}

enum AuthorizationState: String { case ready, outdated, missing, denied, unknown }
enum ProbeOutcome: String { case passed, failed, unknown }

struct ProcessIdentity: Equatable {
    let pid: Int32
    let uid: Int
    let started: String
    let executable: String
    var key: String { "\(pid)|\(started)|\(executable)" }
}

struct RuntimePaths {
    let directory: String
    let executable: String
    var pidFile: String { directory + "/mbim-net.pid" }
    var logFile: String { directory + "/mbim-net.log" }
    static let current = RuntimePaths(directory: "/var/run/magic-bay-lte-v2", executable: "/usr/local/libexec/magic-bay-lte-v2/mbim-net")
    static let legacy = RuntimePaths(directory: "/var/run/magic-bay-lte", executable: "/usr/local/libexec/magic-bay-lte/mbim-net")
    static let controller = "/usr/local/sbin/magic-bay-lte-v2-rootctl"
    static let dnsService = "7E2F4BC0-4241-4C54-8B49-4D42494D5632"
}

struct LiveSignalQuality {
    var observedAt: Date
    var rsrp: Double
    var rsrq: Double
    var rssnr: Double
    var limits: [Int]
    var summary: String {
        func value(_ number: Double, _ index: Int) -> String {
            let relation = limits[index] < 0 ? "≤" : limits[index] > 0 ? "≥" : ""
            return relation + String(format: "%.1f", number)
        }
        return "RSRP \(value(rsrp, 0)) dBm · RSRQ \(value(rsrq, 1)) dB · SNR \(value(rssnr, 2)) dB"
    }
}

struct ConnectionSnapshot {
    var observedAt = Date()
    var devicePresent: Bool? = nil
    var process: ProcessIdentity? = nil
    var processAge: TimeInterval? = nil
    var runtime: RuntimePaths? = nil
    var helperCount = 0
    var competingApplications = [ProcessIdentity]()
    var interface: String? = nil
    var interfacePresent = false
    var address: String? = nil
    var gateway: String? = nil
    var dns = [String]()
    var provider: String? = nil
    var rssi: Int? = nil
    var firmwareVersion: String? = nil
    var hardwareModel: String? = nil
    var liveSignalQuality: LiveSignalQuality? = nil
    var defaultInterface: String? = nil
    var defaultGateway: String? = nil
    var proxySummary = "未配置系统代理"
    var proxyFingerprint = ""
    var dnsFingerprint = ""
    var otherTunnelRoutes = false
    var authorization: AuthorizationState = .unknown
    var rxBytes: Int64? = nil
    var txBytes: Int64? = nil
    var error: String? = nil
    var takeoverReady = false
    var evidenceAvailable = false

    var running: Bool { process != nil }
    var backendInterrupted: Bool {
        guard running else { return false }
        if devicePresent == false { return true }
        guard let error else { return false }
        return ["USB bulk IN failed", "USB bulk OUT failed", "USB bulk OUT short write", "LIBUSB_ERROR_NO_DEVICE",
                "original USB device detached", "MBIM_NET shutdown", "transport_unavailable=1"].contains { error.contains($0) }
    }
    var readOnly: Bool { !competingApplications.isEmpty || helperCount > 1 }
    var routeMatches: Bool { interface != nil && interfacePresent && defaultInterface == interface }
    var fingerprint: String {
        [process?.key ?? "none", interface ?? "", address ?? "", defaultInterface ?? "", defaultGateway ?? "", proxyFingerprint, dnsFingerprint, String(backendInterrupted)].joined(separator: "|")
    }
}

struct ProbeCheck {
    var name: String
    var outcome: ProbeOutcome
    var detail: String
    var elapsed: Double = 0
}

struct ConnectivityEvidence {
    var fingerprint: String
    var checkedAt: Date
    var direct: [ProbeCheck]
    var system: ProbeCheck

    func isFresh(for snapshot: ConnectionSnapshot, now: Date = Date()) -> Bool {
        guard !snapshot.backendInterrupted else { return false }
        let age = now.timeIntervalSince(checkedAt)
        return fingerprint == snapshot.fingerprint && age >= 0 && age <= 90
    }
    var directPassed: Bool { direct.contains { $0.outcome == .passed } }
}

enum Operation: String { case connect, repair, disconnect, authorize }

enum DesktopHandoffPolicy {
    static func target(snapshot: ConnectionSnapshot, currentUID: Int, observeOnly: Bool) -> ProcessIdentity? {
        guard !observeOnly, snapshot.evidenceAvailable, snapshot.helperCount <= 1,
              snapshot.competingApplications.count == 1,
              let target = snapshot.competingApplications.first,
              target.uid == currentUID,
              target.executable.hasSuffix("/Magic Bay LTE.app/Contents/MacOS/MagicBayLTE") else { return nil }
        // Do not strand a temporary legacy connection by closing its only UI.
        if snapshot.running && snapshot.runtime == nil { return nil }
        return target
    }

    static func unchanged(before: ConnectionSnapshot, after: ConnectionSnapshot, currentUID: Int, observeOnly: Bool) -> Bool {
        guard let original = target(snapshot: before, currentUID: currentUID, observeOnly: observeOnly),
              let current = target(snapshot: after, currentUID: currentUID, observeOnly: observeOnly) else { return false }
        return original == current && before.process == after.process && before.helperCount == after.helperCount
    }
}

// All UI mutations happen on the main thread. The coordinator makes repeated clicks
// and late callbacks harmless without depending on a button's appearance.
final class OperationCoordinator {
    private(set) var operation: Operation?
    private(set) var token = UUID()
    func begin(_ operation: Operation, readOnly: Bool) -> UUID? {
        guard self.operation == nil, !readOnly else { return nil }
        self.operation = operation
        token = UUID()
        return token
    }
    @discardableResult func finish(_ token: UUID) -> Bool {
        guard token == self.token, operation != nil else { return false }
        operation = nil
        return true
    }
}

enum ConnectionPolicy {
    static func sessionPresent(_ owner: ProcessIdentity, inventoryAvailable: Bool, entries: [ProcessIdentity]) -> Bool? {
        inventoryAvailable ? entries.contains(owner) : nil
    }

    static func phase(snapshot: ConnectionSnapshot, evidence: ConnectivityEvidence?, operation: Operation?, now: Date = Date()) -> ConnectionPhase {
        if operation == .disconnect { return .stopping }
        if operation == .connect { return .starting }
        if snapshot.helperCount > 1 { return .conflict }
        guard snapshot.evidenceAvailable else { return .checking }
        guard snapshot.running else { return snapshot.devicePresent == false ? .noDevice : .disconnected }
        if snapshot.backendInterrupted { return .incomplete }
        guard snapshot.interfacePresent, snapshot.takeoverReady else {
            return snapshot.takeoverReady || (snapshot.processAge ?? 0) > 60 ? .incomplete : .starting
        }
        guard snapshot.routeMatches else { return .routeMismatch }
        guard let evidence, evidence.isFresh(for: snapshot, now: now) else { return .verifying }
        return evidence.directPassed ? .online : .limited
    }

    static func validAPN(_ apn: String) -> Bool {
        !apn.isEmpty && apn.utf8.count <= 100 && apn.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    static func isManagedHelper(_ path: String) -> Bool {
        path == RuntimePaths.current.executable || path == RuntimePaths.legacy.executable
    }

    static func isLegacyBundleHelper(_ path: String) -> Bool {
        path.hasSuffix("/Magic Bay LTE.app/Contents/MacOS/mbim-net")
    }

    static func isDesktopApplication(_ path: String) -> Bool {
        ["MagicBayLTE", "MagicBayLTE2"].contains(URL(fileURLWithPath: path).lastPathComponent)
    }

    static func parseLog(_ text: String, into snapshot: inout ConnectionSnapshot) {
        snapshot.provider = Match.last(#"provider_name=([^\n]+)"#, text)
        snapshot.rssi = Match.last(#"rssi=(\d+)"#, text).flatMap(Int.init)
        snapshot.firmwareVersion = Match.last(#"(?m)^\s*firmware=([A-Za-z0-9_.-]{1,96})\s*$"#, text)
        snapshot.hardwareModel = Match.last(#"(?m)^\s*hardware=([A-Za-z0-9_.-]{1,96})\s*$"#, text)
        snapshot.liveSignalQuality = nil
        if let process = snapshot.process {
            for line in text.split(separator: "\n").reversed() where line.hasPrefix("MBIM_DIAG ") {
                guard let data = String(line.dropFirst(10)).data(using: .utf8),
                      let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      value["kind"] as? String == "signal_ext", value["pid"] as? Int == Int(process.pid),
                      let stamp = value["ts"] as? Double else { continue }
                let observedAt = Date(timeIntervalSince1970: stamp)
                let age = snapshot.observedAt.timeIntervalSince(observedAt)
                guard age >= -2 && age <= 60, value["ok"] as? Bool == true,
                      let rsrp = value["rsrp_dbm"] as? Double, (-140.0 ... -43.0).contains(rsrp),
                      let rsrq = value["rsrq_db"] as? Double, (-19.5 ... -2.5).contains(rsrq),
                      let rssnr = value["rssnr_db"] as? Double, (-5.0 ... 30.0).contains(rssnr) else { break }
                let limits = ["rsrp_dbm_limit", "rsrq_db_limit", "rssnr_db_limit"].map { value[$0] as? Int ?? 0 }
                guard limits.allSatisfy({ (-1...1).contains($0) }) else { break }
                snapshot.liveSignalQuality = LiveSignalQuality(observedAt: observedAt, rsrp: rsrp, rsrq: rsrq, rssnr: rssnr, limits: limits)
                break
            }
        }
        snapshot.address = Match.last(#"ipv4_address\[0\]=([0-9./]+)"#, text)
        snapshot.gateway = Match.last(#"ipv4_gateway=([0-9.]+)"#, text)
        snapshot.dns = Array(Set(Match.all(#"ipv4_dns\[\d+\]=([0-9.]+)"#, text))).sorted()
        snapshot.interface = Match.last(#"MBIM_NET active=1 utun=(utun\d+)"#, text)
        let events = text.split(separator: "\n").filter {
            $0.contains("MBIM_NET takeover active=") || $0.contains("MBIM_NET active=0") || $0.contains("MBIM_NET takeover restored")
        }
        snapshot.takeoverReady = events.last?.contains("takeover active=1") == true
        let errors = text.split(separator: "\n").filter {
            $0.contains("failed") || $0.contains("not found or not accessible") || $0.contains("did not reach Activated") ||
            $0.contains("original USB device detached") || $0.contains("MBIM_NET shutdown") || $0.contains("transport_unavailable=1") || $0.contains("USB bulk OUT short write")
        }
        snapshot.error = errors.last.map(String.init)
    }

    static func readableError(_ detail: String) -> String {
        if detail.contains("(-128)") || detail.contains("User canceled") { return "已取消授权。连接状态保持不变；准备好后可再次点击。" }
        if detail.contains("password is required") || detail.contains("not allowed") { return "联网组件尚未授权。请在设置中完成一次 macOS 管理员授权。" }
        if detail.contains("not found or not accessible") { return "没有找到可用的 LTE 设备。请检查 USB 连接，然后重新检测。" }
        if detail.contains("device_absent") { return "设备尚未接入。插回 Magic Bay 后再连接，无需退出软件。" }
        if detail.contains("device_presence_unknown") { return "暂时无法确认设备是否已接入。请重新检测；没有停止现有连接。" }
        if detail.contains("recovery_state_changed") { return "设备或连接身份已变化，已取消清理。请重新检测后再连接。" }
        if detail.contains("disconnect_state_changed") { return "连接身份已变化，已取消断开。请重新检测后重试。" }
        if detail.contains("process_inventory_unavailable") { return "暂时无法读取后台状态。已暂停操作，请重新检测。" }
        if detail.contains("initialization_timeout") || detail.contains("NotInitialized") { return "设备仍在初始化或等待运营商网络，本次连接已结束。稍后再点击连接即可。" }
        if detail.contains("sim_not_inserted") { return "设备未检测到 SIM 卡。请检查 SIM 卡安装后重新连接。" }
        if detail.contains("sim_locked") { return "SIM 卡处于锁定状态。请先通过受信任的设备或官方软件解锁，再连接。" }
        if detail.contains("subscriber_not_ready") { return "SIM 服务尚未就绪。请检查卡片与运营商服务状态后重试。" }
        if detail.contains("registration_denied") { return "运营商拒绝了网络注册。请检查 SIM 卡服务状态和当前网络覆盖。" }
        if detail.contains("initialization_cancelled") { return "连接已取消，设备初始化等待已结束。" }
        if detail.contains("initialization_query_failed") || detail.contains("invalid_ready_response") || detail.contains("invalid_radio_response") || detail.contains("invalid_registration") { return "暂时无法确认设备已就绪。本次连接已结束，请重新检测后重试。" }
        if detail.contains("InvalidAccessString") || detail.contains("invalid APN") { return "APN 不正确。请在设置中填写运营商提供的 APN。" }
        if detail.contains("RadioPowerOff") || detail.contains("radio_off") { return "设备无线电处于关闭状态。请检查设备状态后重试。" }
        if detail.contains("LIBUSB_ERROR_BUSY") || detail.contains("another_controller") { return "设备正被其他程序使用。请先退出其他 Magic Bay 窗口程序，再重新检测。" }
        if detail.contains("startup_timeout") { return "连接建立超时。后台尚未确认就绪，请重新检测后查看详情；不会重复启动。" }
        if detail.contains("stop_timeout") { return "后台尚未退出。请稍后重新检测；没有强制结束进程。" }
        return detail.isEmpty ? "操作未完成，请重新检测并查看详情。" : String(detail.prefix(320))
    }
}

enum Match {
    static func all(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 ? ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
    }
    static func last(_ pattern: String, _ text: String) -> String? { all(pattern, text).last }
}

struct TrafficSample {
    var rxPerSecond: Double
    var txPerSecond: Double
    var total: Int64
}

struct TrafficSampler {
    private var previous: (key: String, time: Double, rx: Int64, tx: Int64)?
    mutating func sample(key: String, uptime: Double, rx: Int64, tx: Int64) -> TrafficSample {
        defer { previous = (key, uptime, rx, tx) }
        guard let previous, previous.key == key, uptime > previous.time, rx >= previous.rx, tx >= previous.tx else {
            return TrafficSample(rxPerSecond: 0, txPerSecond: 0, total: rx + tx)
        }
        let elapsed = uptime - previous.time
        return TrafficSample(rxPerSecond: Double(rx - previous.rx) / elapsed, txPerSecond: Double(tx - previous.tx) / elapsed, total: rx + tx)
    }
}

func byteText(_ value: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var number = max(0, value)
    var index = 0
    while number >= 1024 && index < units.count - 1 { number /= 1024; index += 1 }
    return String(format: index == 0 ? "%.0f %@" : "%.1f %@", number, units[index])
}

import Foundation
import Darwin

final class FakeRunner: CommandExecuting {
    var output = ""
    var code: Int32 = 0
    var calls = [(String, [String])]()
    func run(_ executable: String, _ arguments: [String], timeout: Double) -> CommandResult {
        calls.append((executable, arguments))
        return CommandResult(code: code, output: output)
    }
}

@main struct ModelTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        count += 1
        if !condition() { fputs("FAIL \(name)\n", stderr); exit(1) }
        print("PASS \(name)")
    }
    static func checkLargeRuntimeLogs() {
        let base = ProcessInfo.processInfo.environment["MAGIC_BAY_TEST_OUTPUT"] ??
            FileManager.default.currentDirectoryPath + "/tests/run-log-fixtures-\(getpid())"
        let directory = URL(fileURLWithPath: base).appendingPathComponent("log-fixtures-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("runtime.log")
        let header = "provider_name=Fixture LTE\n  ipv4_address[0]=10.23.0.2/24\n  ipv4_gateway=10.23.0.1\n  ipv4_dns[0]=10.23.0.1\nMBIM_NET active=1 utun=utun9\nMBIM_NET takeover active=1\nMBIM_NET ready=1 pid=12345\n"
        let content = header + String(repeating: "MBIM_DIAG synthetic telemetry line\n", count: 20000) + "recent event\n"
        try! Data(content.utf8).write(to: path, options: .withoutOverwriting)
        let inspector = MacInspector()
        let text = inspector.readRegularFile(path.path, requireRoot: false)!
        check(text.utf8.count <= 131072 + 32, "large runtime log reads remain bounded")
        var snapshot = ConnectionSnapshot()
        ConnectionPolicy.parseLog(text, into: &snapshot)
        check(snapshot.interface == "utun9" && snapshot.address == "10.23.0.2/24", "large log retains startup interface and address")
        check(snapshot.takeoverReady && snapshot.dns == ["10.23.0.1"], "large log retains route ownership and DNS evidence")
        check(text.hasSuffix("recent event\n"), "large log retains the latest event")
        let handle = try! FileHandle(forWritingTo: path)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: Data("MBIM_NET takeover restored\nMBIM_NET active=0\nMBIM_NET shutdown transport_unavailable=1\n".utf8))
        try! handle.close()
        let stopped = inspector.readRegularFile(path.path, requireRoot: false)!
        ConnectionPolicy.parseLog(stopped, into: &snapshot)
        check(!snapshot.takeoverReady && snapshot.error?.contains("shutdown") == true, "recent shutdown overrides preserved startup ownership")
        let link = directory.appendingPathComponent("symbolic.log")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        check(inspector.readRegularFile(link.path, requireRoot: false) == nil, "runtime reader refuses symbolic links")
        let fifo = directory.appendingPathComponent("named-pipe").path
        check(mkfifo(fifo, 0o600) == 0 && inspector.readRegularFile(fifo, requireRoot: false) == nil, "runtime reader rejects a FIFO without waiting")
        check(inspector.readRegularFile(path.path, maxBytes: 0, requireRoot: false) == nil, "invalid read bound is rejected")
        // Fixtures stay in this project-local test output for inspection.
    }
    static func main() {
        checkLargeRuntimeLogs()
        check(MacInspector.isModemProbe("/fixture/Magic Bay LTE 2.app/Contents/MacOS/magic-bay-device-info"), "explicit device inspection prevents competing connection actions")
        check(!MacInspector.isModemProbe("/fixture/unrelated-info"), "unrelated utilities are not modem controllers")
        check(ConnectionPolicy.readableError("initialization_timeout").contains("本次连接已结束"), "unready timeout has a clear bounded outcome")
        check(ConnectionPolicy.readableError("reason=sim_not_inserted").contains("SIM 卡"), "missing SIM has a specific next step")
        check(ConnectionPolicy.readableError("reason=registration_denied").contains("运营商拒绝"), "registration denial is not shown as a generic USB error")
        check(ConnectionPolicy.readableError("reason=radio_off").contains("无线电"), "radio-off outcome is distinguished from weak signal")
        var signalState = ConnectionSnapshot()
        signalState.process = ProcessIdentity(pid: 12345, uid: 0, started: "fixture", executable: RuntimePaths.current.executable)
        var signalJSON: [String: Any] = ["kind":"signal_ext", "pid":12345, "ts":signalState.observedAt.timeIntervalSince1970,
            "ok":true, "rsrp_dbm":-98.0, "rsrq_db":-9.0, "rssnr_db":8.0]
        func signalLog() -> String { "firmware=MBLE30_test\nhardware=MBLE30\nMBIM_DIAG " + String(data: try! JSONSerialization.data(withJSONObject: signalJSON), encoding: .utf8)! }
        ConnectionPolicy.parseLog(signalLog(), into: &signalState)
        check(signalState.liveSignalQuality?.rsrp == -98 && signalState.firmwareVersion == "MBLE30_test", "fresh matching telemetry exposes quality and firmware separately")
        signalJSON["pid"] = 54321
        ConnectionPolicy.parseLog(signalLog(), into: &signalState)
        check(signalState.liveSignalQuality == nil, "another backend cannot supply the current signal quality")
        signalJSON["pid"] = 12345; signalJSON["ts"] = signalState.observedAt.timeIntervalSince1970 - 61
        ConnectionPolicy.parseLog(signalLog(), into: &signalState)
        check(signalState.liveSignalQuality == nil, "expired signal is not displayed as live")
        signalJSON["ts"] = signalState.observedAt.timeIntervalSince1970; signalJSON["rsrp_dbm"] = NSNull()
        ConnectionPolicy.parseLog(signalLog(), into: &signalState)
        check(signalState.liveSignalQuality == nil, "unknown physical metric is not displayed as a numeric reading")
        signalJSON["rsrp_dbm"] = -140.0; signalJSON["rsrp_dbm_limit"] = -1
        ConnectionPolicy.parseLog(signalLog(), into: &signalState)
        check(signalState.liveSignalQuality?.summary.contains("≤") == true, "bounded radio endpoint remains a bound in the UI")
        let now = Date()
        var state = ConnectionSnapshot()
        state.evidenceAvailable = true
        state.devicePresent = true
        check(ConnectionPolicy.phase(snapshot: state, evidence: nil, operation: nil) == .disconnected, "device present does not mean connected")
        state.devicePresent = false
        check(ConnectionPolicy.phase(snapshot: state, evidence: nil, operation: nil) == .noDevice, "missing device")
        state.devicePresent = true
        state.process = ProcessIdentity(pid: 111, uid: 0, started: "now", executable: RuntimePaths.current.executable)
        state.helperCount = 1
        state.runtime = .current
        state.interface = "utun6"
        state.address = "10.0.0.2/30"
        state.gateway = "10.0.0.1"
        state.defaultInterface = "utun6"
        state.interfacePresent = true
        state.takeoverReady = true
        check(ConnectionPolicy.phase(snapshot: state, evidence: nil, operation: nil) == .verifying, "PID and route alone never mean internet success")
        let passed = ProbeCheck(name: "test", outcome: .passed, detail: "HTTPS 200")
        let failed = ProbeCheck(name: "test", outcome: .failed, detail: "timeout")
        var evidence = ConnectivityEvidence(fingerprint: state.fingerprint, checkedAt: now, direct: [passed, failed], system: failed)
        check(ConnectionPolicy.phase(snapshot: state, evidence: evidence, operation: nil, now: now) == .online, "one valid endpoint proves LTE despite system proxy failure")
        check(evidence.system.outcome == .failed, "system failure retained separately")
        evidence.direct = [failed, failed]
        check(ConnectionPolicy.phase(snapshot: state, evidence: evidence, operation: nil, now: now) == .limited, "HTTPS failures are not green")
        evidence.direct = [passed]
        check(!evidence.isFresh(for: state, now: now.addingTimeInterval(91)), "connectivity expires")
        check(!evidence.isFresh(for: state, now: now.addingTimeInterval(-1)), "future timestamps not trusted")
        var changed = state
        changed.defaultInterface = "utun4"
        check(!evidence.isFresh(for: changed, now: now), "route switch invalidates probe")
        check(ConnectionPolicy.phase(snapshot: changed, evidence: evidence, operation: nil, now: now) == .routeMismatch, "other utun is not LTE")
        changed = state
        changed.process = ProcessIdentity(pid: 111, uid: 0, started: "later", executable: RuntimePaths.current.executable)
        check(!evidence.isFresh(for: changed, now: now), "PID reuse invalidates probe")
        changed = state
        changed.proxyFingerprint = "new proxy"
        check(!evidence.isFresh(for: changed, now: now), "proxy change invalidates probe")
        changed = state
        changed.process = nil
        changed.devicePresent = true
        check(ConnectionPolicy.phase(snapshot: changed, evidence: evidence, operation: nil) == .disconnected, "stale successful log does not resurrect stopped process")
        changed = state
        changed.helperCount = 2
        check(ConnectionPolicy.phase(snapshot: changed, evidence: evidence, operation: nil) == .conflict, "multiple helpers blocked")
        check(ConnectionPolicy.phase(snapshot: state, evidence: evidence, operation: .disconnect) == .stopping, "operation takes precedence over old log")
        check(ConnectionPolicy.validAPN("3gnet") && ConnectionPolicy.validAPN("internet.example"), "valid APN")
        for apn in ["", "a b", "--help", "a;id", "$(id)", "中国", String(repeating: "a", count: 101)] { check(!ConnectionPolicy.validAPN(apn), "invalid APN rejected") }
        check(ConnectionPolicy.readableError("User canceled. (-128)").contains("取消"), "authorization cancel explained without success")

        let operation = OperationCoordinator()
        let token = operation.begin(.connect, readOnly: false)!
        check(operation.begin(.connect, readOnly: false) == nil, "double click creates only one operation")
        check(operation.begin(.disconnect, readOnly: false) == nil, "opposite operation cannot race")
        check(!operation.finish(UUID()), "stale callback cannot unlock active operation")
        check(operation.finish(token), "matching callback finishes operation")
        check(operation.begin(.connect, readOnly: true) == nil, "observer cannot mutate")
        check(ControllerPolicy.decide(action: "start", apn: "3gnet", snapshot: state) == .alreadyRunning, "start is idempotent and never silently repairs routes")
        check(ControllerPolicy.decide(action: "repair", apn: "", snapshot: state) == .repair, "verified route repair permitted")
        changed = state
        changed.interfacePresent = false
        check(ControllerPolicy.decide(action: "repair", apn: "", snapshot: changed) == .refuse("repair_requires_verified_interface"), "missing interface prevents repair from log")
        changed = state
        changed.process = nil
        changed.helperCount = 0
        check(ControllerPolicy.decide(action: "stop", apn: "", snapshot: changed) == .alreadyStopped, "already stopped does not clear routes or DNS")
        check(ControllerPolicy.decide(action: "start", apn: "3gnet", snapshot: changed) == .startNew, "idle start allowed")
        changed.helperCount = 1
        if case .refuse = ControllerPolicy.decide(action: "start", apn: "3gnet", snapshot: changed) { check(true, "unknown helper blocks start") } else { check(false, "unknown helper blocks start") }
        changed = state
        changed.competingApplications = [ProcessIdentity(pid: 2, uid: 501, started: "now", executable: "/old/Magic Bay LTE.app/Contents/MacOS/MagicBayLTE")]
        for action in ["start", "repair", "stop"] {
            if case .refuse = ControllerPolicy.decide(action: action, apn: "3gnet", snapshot: changed) { check(true, "old desktop blocks \(action)") } else { check(false, "old desktop blocks \(action)") }
        }
        changed = state
        changed.evidenceAvailable = false
        if case .refuse = ControllerPolicy.decide(action: "stop", apn: "", snapshot: changed) { check(true, "failed inventory cannot authorize stop") } else { check(false, "failed inventory cannot authorize stop") }

        var handoff = state
        let oldWindow = ProcessIdentity(pid: 2, uid: 501, started: "old-window-start", executable: "/old/Magic Bay LTE.app/Contents/MacOS/MagicBayLTE")
        handoff.competingApplications = [oldWindow]
        check(DesktopHandoffPolicy.target(snapshot: handoff, currentUID: 501, observeOnly: false) == oldWindow, "known old UI has an actionable handoff")
        check(DesktopHandoffPolicy.target(snapshot: handoff, currentUID: 501, observeOnly: true) == nil, "explicit observe mode stays read-only")
        check(DesktopHandoffPolicy.target(snapshot: handoff, currentUID: 502, observeOnly: false) == nil, "handoff cannot quit another user application")
        var handoffChanged = handoff
        handoffChanged.helperCount = 2
        check(DesktopHandoffPolicy.target(snapshot: handoffChanged, currentUID: 501, observeOnly: false) == nil, "multiple backends prevent automatic UI handoff")
        handoffChanged = handoff
        handoffChanged.evidenceAvailable = false
        check(DesktopHandoffPolicy.target(snapshot: handoffChanged, currentUID: 501, observeOnly: false) == nil, "missing inventory prevents UI handoff")
        handoffChanged = handoff
        handoffChanged.runtime = nil
        check(DesktopHandoffPolicy.target(snapshot: handoffChanged, currentUID: 501, observeOnly: false) == nil, "temporary legacy connection retains its control UI")
        handoffChanged = handoff
        handoffChanged.competingApplications = [state.process!]
        check(DesktopHandoffPolicy.target(snapshot: handoffChanged, currentUID: 0, observeOnly: false) == nil, "backend is never a quit target")
        handoffChanged.competingApplications = [ProcessIdentity(pid: 3, uid: 501, started: "now", executable: "/tmp/MagicBayLTE")]
        check(DesktopHandoffPolicy.target(snapshot: handoffChanged, currentUID: 501, observeOnly: false) == nil, "matching process name alone is not enough")
        handoffChanged = handoff
        handoffChanged.competingApplications.append(ProcessIdentity(pid: 4, uid: 501, started: "now", executable: "/copy/Magic Bay LTE 2.app/Contents/MacOS/MagicBayLTE2"))
        check(DesktopHandoffPolicy.target(snapshot: handoffChanged, currentUID: 501, observeOnly: false) == nil, "another v2 controller is not automatically terminated")
        check(DesktopHandoffPolicy.unchanged(before: handoff, after: handoff, currentUID: 501, observeOnly: false), "unchanged ownership permits graceful UI quit")
        handoffChanged = handoff
        handoffChanged.competingApplications = [ProcessIdentity(pid: oldWindow.pid, uid: 501, started: "reused-pid", executable: oldWindow.executable)]
        check(!DesktopHandoffPolicy.unchanged(before: handoff, after: handoffChanged, currentUID: 501, observeOnly: false), "PID reuse during confirmation cancels handoff")
        handoffChanged = handoff
        handoffChanged.process = nil
        check(!DesktopHandoffPolicy.unchanged(before: handoff, after: handoffChanged, currentUID: 501, observeOnly: false), "backend change during confirmation cancels handoff")
        handoff.process = nil
        handoff.runtime = nil
        handoff.helperCount = 0
        check(DesktopHandoffPolicy.target(snapshot: handoff, currentUID: 501, observeOnly: false) == oldWindow, "disconnected screen still exposes the handoff entry")

        var parsed = ConnectionSnapshot()
        ConnectionPolicy.parseLog("MBIM_NET active=1 utun=utun6\nMBIM_NET takeover active=1 default_gateway=10.0.0.1 interface=utun6\nMBIM_NET active=0", into: &parsed)
        check(!parsed.takeoverReady, "last lifecycle event wins")
        var sampler = TrafficSampler()
        _ = sampler.sample(key: "first", uptime: 1, rx: 100, tx: 20)
        let sample = sampler.sample(key: "first", uptime: 5, rx: 500, tx: 60)
        check(sample.rxPerSecond == 100 && sample.txPerSecond == 10, "traffic uses actual elapsed time")
        check(sampler.sample(key: "second", uptime: 7, rx: 900, tx: 200).rxPerSecond == 0, "traffic resets on connection identity change")
        check(sampler.sample(key: "second", uptime: 9, rx: 0, tx: 0).rxPerSecond == 0, "counter reset does not show negative rate")
        let counters = MacInspector.parseCounters("Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\nutun6 1500 <Link#24> 12 0 500 10 0 200 0", interface: "utun6")
        // Link-layer rows omit the empty Address column; parser handles that explicitly.
        check(counters?.0 == 500 && counters?.1 == 200, "netstat Link row aligns missing Address column")
        let fake = FakeRunner()
        fake.output = " 5741     0 Sun Sep  6 09:57:54 2026     /usr/local/libexec/magic-bay-lte/mbim-net\n 5707   501 Sun Sep  6 09:57:49 2026     /old/Magic Bay LTE.app/Contents/MacOS/MagicBayLTE\n"
        let processes = MacInspector(runner: fake).processes()
        check(processes.entries.first?.executable == RuntimePaths.legacy.executable, "ps spacing preserves exact executable identity")
        check(processes.entries.last?.executable == "/old/Magic Bay LTE.app/Contents/MacOS/MagicBayLTE", "process paths with spaces preserved")
        fake.calls = []
        fake.output = "probe_code=200 elapsed=0.2"
        let probe = MacInspector(runner: fake).probe(name: "test", url: "https://example.com/", interface: "utun6")
        check(probe.outcome == .passed, "real HTTP result parsed")
        check(fake.calls[0].1.first == "--disable", "user curlrc cannot alter probe")
        check(fake.calls[0].1.contains("if!utun6") && fake.calls[0].1.contains("--noproxy"), "probe explicitly binds LTE and bypasses proxies")
        fake.code = 6
        fake.output = "Could not resolve host"
        check(MacInspector(runner: fake).probe(name: "test", url: "https://example.com/", interface: "utun6").detail.contains("解析"), "DNS failure distinguished")
        let timeout = CommandRunner().run("/bin/sleep", ["3"], timeout: 0.05)
        check(timeout.timedOut && timeout.code == 124, "read-only child timeout is bounded")
        changed = state
        changed.dnsFingerprint = "new resolver"
        check(!evidence.isFresh(for: changed, now: now), "DNS change invalidates old connectivity evidence")
        changed = state
        changed.interfacePresent = false
        check(ConnectionPolicy.phase(snapshot: changed, evidence: nil, operation: nil) == .incomplete, "lost interface does not spin as startup forever")
        changed.takeoverReady = false
        changed.processAge = 61
        check(ConnectionPolicy.phase(snapshot: changed, evidence: nil, operation: nil) == .incomplete, "startup has a visible timeout state")
        changed = state
        changed.process = ProcessIdentity(pid: 111, uid: 0, started: "now", executable: RuntimePaths.legacy.executable)
        changed.defaultInterface = "utun4"
        if case .refuse = ControllerPolicy.decide(action: "stop", apn: "", snapshot: changed) { check(true, "legacy cleanup cannot overwrite a newly selected VPN route") } else { check(false, "legacy cleanup cannot overwrite a newly selected VPN route") }
        changed = state
        changed.runtime = .current
        changed.devicePresent = true
        changed.error = "USB bulk IN failed: LIBUSB_ERROR_IO"
        check(ConnectionPolicy.phase(snapshot: changed, evidence: evidence, operation: nil) == .incomplete, "a failed USB session cannot reuse successful connectivity proof")
        check(ControllerPolicy.decide(action: "start", apn: "3gnet", snapshot: changed) != .alreadyRunning, "an explicit connect request can recover a failed owned session")
        changed.devicePresent = false
        if case .refuse = ControllerPolicy.decide(action: "start", apn: "3gnet", snapshot: changed) { check(true, "removed device cannot start a new connection") } else { check(false, "removed device cannot start a new connection") }
        changed.devicePresent = nil
        check(ControllerPolicy.decide(action: "start", apn: "3gnet", snapshot: changed) == .refuse("device_presence_unknown"), "unknown USB evidence cannot authorize recovery of an existing owner")
        changed.devicePresent = true
        changed.process = ProcessIdentity(pid: 111, uid: 0, started: "now", executable: RuntimePaths.legacy.executable)
        check(ControllerPolicy.decide(action: "start", apn: "3gnet", snapshot: changed) == .refuse("unverified_recovery_backend"), "recovery cannot stop a legacy or unrelated USB owner")
        let owner = state.process!
        check(ConnectionPolicy.sessionPresent(owner, inventoryAvailable: false, entries: []) == nil, "a failed inventory cannot imply that a proxy session owner exited")
        check(ConnectionPolicy.sessionPresent(owner, inventoryAvailable: true, entries: [owner]) == true, "the exact owner retains its proxy companion")
        let reused = ProcessIdentity(pid: owner.pid, uid: owner.uid, started: "reused PID", executable: owner.executable)
        check(ConnectionPolicy.sessionPresent(owner, inventoryAvailable: true, entries: [reused]) == false, "a reused PID does not retain the old proxy companion")
        print("ALL \(count) TESTS PASSED; no USB, network mutation or sudo executed")
    }
}

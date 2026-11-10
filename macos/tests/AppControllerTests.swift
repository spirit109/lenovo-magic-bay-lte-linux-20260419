import Foundation
import Darwin

@main struct AppControllerTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        count += 1
        guard condition() else { fputs("FAIL \(name)\n", stderr); exit(1) }
        print("PASS \(name)")
    }
    static func main() {
        let model = AppController(fixtureMode: true)
        model.snapshot.evidenceAvailable = true
        model.snapshot.devicePresent = true
        let oldUI = ProcessIdentity(pid: 123, uid: Int(getuid()), started: "fixture", executable: "/fixture/Magic Bay LTE.app/Contents/MacOS/MagicBayLTE")
        model.snapshot.competingApplications = [oldUI]
        check(model.readOnly && model.primaryEnabled && model.primaryTitle == "启用新版控制", "legacy idle UI exposes an enabled control entry")
        model.primaryAction()
        check(model.snapshot.competingApplications == [oldUI] && !model.handingOver, "fixture action cannot quit a real app")
        model.handingOver = true
        check(!model.primaryEnabled && model.busy, "handoff blocks duplicate clicks and network actions")
        model.handingOver = false
        model.snapshot.competingApplications = []
        model.snapshot.authorization = .missing
        check(model.primaryEnabled && model.primaryTitle == "授权并设置联网", "handoff completion exposes first-time authorization")
        model.snapshot.authorization = .ready
        check(model.primaryEnabled && model.primaryTitle == "连接 LTE", "disconnected authorized app has an enabled connect button")
        model.refreshing = true
        check(model.primaryEnabled && model.refreshEnabled, "background polling does not blink enabled controls")
        model.userRefreshing = true
        check(!model.primaryEnabled && !model.refreshEnabled, "explicit refresh still shows a single busy state")
        model.userRefreshing = false
        let observer = AppController(observeOnly: true, fixtureMode: true)
        observer.snapshot = model.snapshot
        check(!observer.primaryEnabled && observer.primaryTitle == "只读观察中", "explicit observer never silently enables connection")
        model.refreshing = false
        model.snapshot.competingApplications = [oldUI]
        model.snapshot.process = ProcessIdentity(pid: 456, uid: 0, started: "fixture", executable: "/fixture/Magic Bay LTE.app/Contents/MacOS/mbim-net")
        check(!model.primaryEnabled && model.readOnlyExplanation.contains("临时连接"), "temporary legacy session retains a usable old control path")
        let online = AppController(fixtureMode: true)
        online.snapshot.evidenceAvailable = true
        online.snapshot.authorization = .ready
        online.snapshot.process = ProcessIdentity(pid: 999, uid: 0, started: "fixture", executable: RuntimePaths.current.executable)
        online.snapshot.runtime = .current
        online.snapshot.helperCount = 1
        online.snapshot.interface = "utun9"
        online.snapshot.interfacePresent = true
        online.snapshot.defaultInterface = "utun9"
        online.snapshot.takeoverReady = true
        let passed = ProbeCheck(name: "fixture", outcome: .passed, detail: "fixture")
        let proof = ConnectivityEvidence(fingerprint: online.snapshot.fingerprint, checkedAt: Date(), direct: [passed], system: passed)
        online.evidence = proof
        let stableMenu = online.menuRevision
        online.refreshing = true
        online.checking = true
        check(online.primaryEnabled && !online.showsProbeProgress, "valid online state stays quiet during automatic checks")
        check(online.menuRevision == stableMenu, "automatic polling does not rebuild an unchanged menu")
        online.notice = AppController.pendingVerificationNotice
        online.userRefreshing = true
        online.applyVerification(proof, current: online.snapshot)
        check(online.notice.isEmpty && !online.userRefreshing && !online.checking, "completed check clears stale progress banner")
        online.notice = "其他需要保留的提示"
        online.applyVerification(proof, current: online.snapshot)
        check(online.notice == "其他需要保留的提示", "successful check preserves unrelated user feedback")
        var changed = online.snapshot
        changed.defaultInterface = "en0"
        online.applyVerification(proof, current: changed)
        check(online.evidence == nil, "quiet refresh does not preserve stale proof across route changes")
        online.operation = .disconnect
        online.applyVerification(proof, current: online.snapshot)
        check(!online.primaryEnabled && online.evidence == nil, "real network operations remain protected during background checks")
        online.operation = nil
        online.snapshot.devicePresent = true
        online.snapshot.error = "USB bulk IN failed: LIBUSB_ERROR_NO_DEVICE"
        check(online.primaryEnabled && online.primaryTitle == "清理并重新连接", "reinsertion with a failed backend exposes one recovery action")
        online.snapshot.devicePresent = false
        check(online.primaryEnabled && online.primaryTitle == "清理已断开的连接", "unplugged backend can be released without Activity Monitor")
        online.snapshot.authorization = .outdated
        check(online.primaryTitle == "断开 LTE 以更新组件", "a new UI cannot silently claim that old network components were upgraded")
        online.snapshot.process = nil
        online.snapshot.devicePresent = true
        check(online.primaryTitle == "更新联网组件", "an idle old component installation has an explicit update action")
        let disconnect = AppController(fixtureMode: true)
        disconnect.snapshot.evidenceAvailable = true
        disconnect.snapshot.authorization = .ready
        disconnect.snapshot.process = ProcessIdentity(pid: 998, uid: 0, started: "fixture", executable: RuntimePaths.current.executable)
        disconnect.snapshot.runtime = .current
        disconnect.snapshot.helperCount = 1
        disconnect.snapshot.interface = "utun9"
        disconnect.snapshot.interfacePresent = true
        disconnect.snapshot.defaultInterface = "utun9"
        disconnect.snapshot.takeoverReady = true
        let failed = ProbeCheck(name: "fixture", outcome: .failed, detail: "timeout")
        disconnect.evidence = ConnectivityEvidence(fingerprint: disconnect.snapshot.fingerprint, checkedAt: Date(), direct: [failed], system: failed)
        check(disconnect.phase == .limited && disconnect.showsSeparateDisconnect && disconnect.disconnectEnabled, "failed internet checks retain a visible enabled disconnect action")
        disconnect.snapshot.defaultInterface = "en0"
        check(disconnect.phase == .routeMismatch && disconnect.showsSeparateDisconnect && disconnect.disconnectEnabled, "another default network does not hide stopping the owned LTE session")
        disconnect.snapshot.interfacePresent = false
        check(disconnect.phase == .incomplete && disconnect.disconnectEnabled, "an incomplete owned session can still be stopped")
        disconnect.snapshot.interfacePresent = true
        disconnect.snapshot.defaultInterface = "utun9"
        disconnect.evidence = nil
        check(disconnect.phase == .verifying && disconnect.disconnectEnabled, "connectivity verification does not lock out disconnect")
        disconnect.userRefreshing = true
        check(disconnect.showsSeparateDisconnect && disconnect.disconnectEnabled, "explicit HTTPS refresh does not strand a live connection")
        disconnect.userRefreshing = false
        disconnect.snapshot.authorization = .outdated
        check(disconnect.disconnectEnabled, "an authorized previous controller can stop its session before upgrade")
        disconnect.operation = .connect
        check(!disconnect.disconnectEnabled, "disconnect cannot race an active control operation")
        disconnect.operation = nil
        disconnect.snapshot.competingApplications = [oldUI]
        check(!disconnect.disconnectEnabled, "a second controller retains read-only protection for disconnect")
        disconnect.snapshot.competingApplications = []
        disconnect.snapshot.authorization = .denied
        check(!disconnect.disconnectEnabled, "disconnect never bypasses missing control permission")
        disconnect.snapshot.authorization = .ready
        disconnect.snapshot.process = nil
        check(!disconnect.disconnectEnabled && !disconnect.showsSeparateDisconnect, "a stopped session has no active disconnect command")
        print("ALL \(count) APP CONTROLLER TESTS PASSED; fixture-only, no GUI, USB or network actions")
    }
}

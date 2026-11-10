import Cocoa
import SwiftUI
import Combine

final class DesktopDelegate: NSObject, NSApplicationDelegate {
    let model = AppController(observeOnly: CommandLine.arguments.contains("--observe"))
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var subscriptions = Set<AnyCancellable>()
    private var lastMenuRevision: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 880), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Magic Bay LTE 2"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 620)
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Magic Bay LTE 2")
        model.objectWillChange.debounce(for: .milliseconds(80), scheduler: RunLoop.main).sink { [weak self] _ in self?.updateMenu() }.store(in: &subscriptions)
        updateMenu()
        model.start()
        if !CommandLine.arguments.contains("--quiet") { showWindow() }
    }
    func updateMenu() {
        let revision = model.menuRevision
        guard revision != lastMenuRevision else { return }
        lastMenuRevision = revision
        let menu = NSMenu()
        menu.autoenablesItems = false
        let state = NSMenuItem(title: model.phase.title, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        let summary = NSMenuItem(title: model.readOnly ? "只读观察 · 连接受保护" : "退出应用不会断网", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())
        if model.primaryTitle != "断开 LTE" {
            let primary = NSMenuItem(title: model.primaryTitle, action: #selector(primaryAction), keyEquivalent: "")
            primary.target = self
            primary.isEnabled = model.primaryEnabled
            menu.addItem(primary)
        }
        if model.snapshot.running {
            let disconnect = NSMenuItem(title: "断开 LTE", action: #selector(disconnect), keyEquivalent: "")
            disconnect.target = self
            disconnect.isEnabled = model.disconnectEnabled
            menu.addItem(disconnect)
        }
        let refresh = NSMenuItem(title: "重新检测", action: #selector(refresh), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = model.refreshEnabled
        menu.addItem(refresh)
        menu.addItem(.separator())
        let show = NSMenuItem(title: "显示窗口", action: #selector(showWindow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let quit = NSMenuItem(title: "退出应用（保留 LTE）", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.title = model.phase == .online ? " LTE" : " LTE·"
        statusItem.button?.toolTip = model.phase.title + (model.readOnly ? " · 只读观察" : "")
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func primaryAction() { model.primaryAction() }
    @objc func disconnect() { model.confirmDisconnect() }
    @objc func refresh() { model.refresh(forceProbe: true, userInitiated: true) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.handingOver ? "控制切换尚未结束" : "联网操作尚未结束"
        alert.informativeText = "请等待操作结束，或在系统授权窗口中取消后再退出。"
        alert.runModal()
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { model.stopObserving() }
}

func fixture(_ scenario: String) -> AppController {
    let model = AppController(observeOnly: scenario == "forced-observe", fixtureMode: true)
    var state = ConnectionSnapshot()
    state.evidenceAvailable = true
    state.authorization = .ready
    state.devicePresent = true
    if !["disconnected", "no-device", "observe-idle", "forced-observe"].contains(scenario) {
        state.process = ProcessIdentity(pid: 12345, uid: 0, started: "preview", executable: RuntimePaths.current.executable)
        state.runtime = .current
        state.helperCount = 1
        state.interface = "utun6"
        state.interfacePresent = true
        state.takeoverReady = true
        state.address = "10.0.0.2/30"
        state.gateway = "10.0.0.1"
        state.dns = ["223.5.5.5", "119.29.29.29"]
        state.provider = "中国联通"
        state.defaultInterface = scenario == "route-changed" ? "utun4" : "utun6"
        state.proxySummary = "系统代理已启用"
        state.otherTunnelRoutes = true
        model.traffic = TrafficSample(rxPerSecond: 1290240, txPerSecond: 27648, total: 398458880)
    }
    if scenario == "observe" || scenario == "observe-idle" {
        state.competingApplications = [ProcessIdentity(pid: 54321, uid: Int(getuid()), started: "preview", executable: "/preview/Magic Bay LTE.app/Contents/MacOS/MagicBayLTE")]
    }
    if scenario == "observe-idle" { state.authorization = .missing }
    if scenario == "no-device" { state.devicePresent = false }
    if ["reinserted", "device-removed"].contains(scenario) {
        state.error = "USB bulk IN failed: LIBUSB_ERROR_NO_DEVICE"
        state.devicePresent = scenario == "reinserted"
    }
    if scenario == "authorize" {
        state.authorization = .missing
        state.runtime = .legacy
        state.process = ProcessIdentity(pid: 12345, uid: 0, started: "preview", executable: RuntimePaths.legacy.executable)
        model.expanded = true
    }
    if scenario == "cancelled" { state.authorization = .denied; model.notice = ConnectionPolicy.readableError("User canceled (-128)"); model.noticeIsError = true }
    if scenario == "signal-quality" {
        state.hardwareModel = "MBLE30"
        state.firmwareVersion = "MBLE30_4.0.11_EQ101"
        state.rssi = 21
        state.liveSignalQuality = LiveSignalQuality(observedAt: Date(), rsrp: -98, rsrq: -9, rssnr: 8, limits: [0, 0, 0])
        model.expanded = true
        model.notice = "离屏示例，仅用于界面检查，不代表当前连接。"
    }
    model.snapshot = state
    let directPassed = scenario != "limited"
    model.evidence = ConnectivityEvidence(fingerprint: state.fingerprint, checkedAt: Date(), direct: [ProbeCheck(name: "Apple", outcome: directPassed ? .passed : .failed, detail: "HTTPS 检测"), ProbeCheck(name: "百度", outcome: directPassed ? .passed : .failed, detail: "HTTPS 检测")], system: ProbeCheck(name: "系统访问", outcome: scenario == "proxy-failed" ? .failed : .passed, detail: "系统网络策略"))
    if !state.running { model.evidence = nil }
    if scenario == "starting" { model.operation = .connect; model.evidence = nil }
    return model
}

let arguments = CommandLine.arguments
if arguments.contains("--inspect") {
    let inspector = MacInspector()
    var state = inspector.collect()
    state.authorization = inspector.authorization()
    let evidence = arguments.contains("--verify") ? inspector.verify(state) : nil
    if evidence != nil {
        let authorization = state.authorization
        state = inspector.collect()
        state.authorization = authorization
    }
    print(diagnostics(snapshot: state, evidence: evidence))
    exit(state.evidenceAvailable ? 0 : 1)
}

if let index = arguments.firstIndex(of: "--render-preview"), arguments.count > index + 1 {
    let destination = arguments[index + 1]
    let scenario = arguments.count > index + 2 ? arguments[index + 2] : "observe"
    let dark = arguments.contains("--dark")
    let width: CGFloat = arguments.contains("--compact") ? 640 : 760
    let height: CGFloat = arguments.contains("--tall") ? 1500 : 1050
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    application.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let model = fixture(scenario)
    let hosting = NSHostingView(rootView: MainView(model: model).environment(\.controlActiveState, .active))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(1) }
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    do { try png.write(to: URL(fileURLWithPath: destination)); print("preview=\(destination) scenario=\(scenario) offscreen=1 primary_enabled=\(model.primaryEnabled) primary_title=\(model.primaryTitle)") }
    catch { fputs("\(error)\n", stderr); exit(1) }
    exit(0)
}

if CommandLine.arguments.contains("--clean-start") {
    UserDefaults.standard.removePersistentDomain(forName: "local.magicbay.lte.v2")
    UserDefaults.standard.synchronize()
}
let app = NSApplication.shared
let delegate = DesktopDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

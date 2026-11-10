import Cocoa
import Combine

final class AppController: ObservableObject {
    @Published var snapshot = ConnectionSnapshot()
    @Published var evidence: ConnectivityEvidence?
    @Published var checking = false
    @Published var refreshing = false
    @Published var userRefreshing = false
    @Published var handingOver = false
    @Published var operation: Operation?
    @Published var notice = ""
    @Published var noticeIsError = false
    @Published var expanded = false
    @Published var apn: String
    @Published var traffic: TrafficSample?
    let observeOnly: Bool
    let fixtureMode: Bool
    private var timer: Timer?
    private let coordinator = OperationCoordinator()
    private let queue = DispatchQueue(label: "local.magicbay.lte.v2.operations", qos: .utility)
    private var lastAuthorizationCheck = Date.distantPast
    private var lastProbeAt = Date.distantPast
    private var sampler = TrafficSampler()
    private var lastProcessKey: String?
    private var pendingUserRefresh = false
    static let pendingVerificationNotice = "网络配置操作已结束，正在检查实际联网能力。"

    init(observeOnly: Bool = false, fixtureMode: Bool = false) {
        self.observeOnly = observeOnly
        self.fixtureMode = fixtureMode
        self.apn = fixtureMode ? "3gnet" : (UserDefaults.standard.string(forKey: "lteAPN") ?? "3gnet")
    }

    var readOnly: Bool { observeOnly || snapshot.readOnly }
    var busy: Bool { operation != nil || handingOver }
    var handoffTarget: ProcessIdentity? { DesktopHandoffPolicy.target(snapshot: snapshot, currentUID: Int(getuid()), observeOnly: observeOnly) }
    var canHandoff: Bool { handoffTarget != nil }
    var primaryEnabled: Bool {
        guard !busy, !userRefreshing, snapshot.evidenceAvailable else { return false }
        if readOnly { return canHandoff }
        return phase != .noDevice && phase != .conflict
    }
    var refreshEnabled: Bool { !busy && !userRefreshing }
    var disconnectEnabled: Bool {
        guard !readOnly, !busy, snapshot.running, snapshot.helperCount == 1,
              snapshot.authorization == .ready || snapshot.authorization == .outdated else { return false }
        return ControllerPolicy.decide(action: "stop", apn: "", snapshot: snapshot) == .stop
    }
    var showsSeparateDisconnect: Bool { snapshot.running && (primaryTitle != "断开 LTE" || !primaryEnabled) }
    var showsProbeProgress: Bool { userRefreshing || (checking && freshEvidence == nil) || (refreshing && !snapshot.evidenceAvailable) }
    var menuRevision: String { [phase.rawValue, String(readOnly), primaryTitle, String(primaryEnabled), String(refreshEnabled), String(snapshot.running), String(disconnectEnabled)].joined(separator: "|") }
    var readOnlyExplanation: String {
        if observeOnly { return "本次以只读模式启动。需要连接时，请退出此窗口程序，再正常打开 Magic Bay LTE 2。" }
        if canHandoff { return "旧版界面仍在运行。点击下方「启用新版控制」，确认后退出旧版界面；现有 LTE 后台会继续运行。" }
        if snapshot.running && snapshot.runtime == nil { return "旧版临时连接尚无法安全接管。请在可断网时用旧版「关闭互联网」，再退出旧版界面。" }
        if snapshot.helperCount > 1 { return "多个联网后台正在使用设备。请先处理重复连接，再重新检测。" }
        return "另一个 Magic Bay 控制程序仍在运行。请退出多余的窗口程序，再重新检测；关闭窗口不等于退出应用。"
    }
    var phase: ConnectionPhase { ConnectionPolicy.phase(snapshot: snapshot, evidence: evidence, operation: operation) }
    var freshEvidence: ConnectivityEvidence? { evidence.flatMap { $0.isFresh(for: snapshot) ? $0 : nil } }
    var primaryTitle: String {
        if handingOver { return "正在启用新版控制…" }
        if readOnly { return canHandoff ? "启用新版控制" : "只读观察中" }
        if operation == .connect { return "正在连接…" }
        if operation == .disconnect { return "正在断开…" }
        if operation == .authorize { return "等待系统授权…" }
        if operation == .repair { return "正在修复路径…" }
        if snapshot.authorization == .outdated { return snapshot.running ? "断开 LTE 以更新组件" : "更新联网组件" }
        if snapshot.authorization != .ready { return snapshot.running ? "设置联网权限" : "授权并设置联网" }
        if snapshot.backendInterrupted && snapshot.process?.executable == RuntimePaths.current.executable {
            return snapshot.devicePresent == false ? "清理已断开的连接" : "清理并重新连接"
        }
        if phase == .routeMismatch { return "切回 LTE 上网" }
        if phase == .limited { return "重新检测上网" }
        return snapshot.running ? "断开 LTE" : "连接 LTE"
    }
    var subtitle: String {
        switch phase {
        case .online:
            if freshEvidence?.system.outcome == .failed { return "LTE 直连正常，系统访问未通过。请检查代理或 VPN。" }
            return snapshot.otherTunnelRoutes ? "LTE 直连检测通过。代理与 VPN 仍按各自策略运行。" : "LTE 直连检测通过，可以开始使用网络。"
        case .limited:
            if freshEvidence?.direct.contains(where: { $0.detail.contains("解析") }) == true {
                return "LTE 接口已就绪，但域名解析未通过。可重新检测，并在详情中检查 DNS、代理与 VPN。"
            }
            return "已建立连接，但检测站点尚未通过。可重新检测，或展开详情定位问题。"
        case .routeMismatch: return "LTE 后台仍在运行；当前系统默认路径不是此 LTE 接口。"
        case .starting: return "正在等待设备、IP 地址与路由就绪，请勿重复操作。"
        case .incomplete:
            if snapshot.backendInterrupted {
                return snapshot.devicePresent == false ? "设备已拔出，正在释放旧连接。插回后即可再次连接，无需退出软件。" : "原连接已经失效。点击下方按钮清理并重新连接，无需手动退出后台进程。"
            }
            return snapshot.error.map(ConnectionPolicy.readableError) ?? "后台已启动，但网络尚未就绪。请重新检测；需要重连时，可先断开 LTE 再连接。"
        case .verifying: return "连接已建立，正在检查真实的 HTTPS 访问能力。"
        case .noDevice: return "请将设备接入 USB，确认 SIM 卡已插好，然后重新检测。"
        case .disconnected: return "点击连接后，会把系统默认网络切换到 LTE。"
        case .conflict: return "多个程序正在使用设备。请退出其他控制程序后重新检测。"
        case .stopping: return "正在等待后台退出并恢复网络设置。"
        case .checking: return "正在读取现有网络，不会自动建立或切换连接。"
        }
    }

    func start() {
        guard !fixtureMode else { return }
        refresh(forceProbe: true)
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopObserving() { timer?.invalidate(); timer = nil }

    func refresh(forceProbe: Bool = false, userInitiated: Bool = false) {
        guard !fixtureMode, !busy else { return }
        if userInitiated { userRefreshing = true }
        guard !refreshing else {
            if userInitiated { pendingUserRefresh = true }
            return
        }
        refreshing = true
        let checkAuthorization = Date().timeIntervalSince(lastAuthorizationCheck) > 60
        queue.async {
            let inspector = MacInspector()
            var current = inspector.collect()
            if checkAuthorization { current.authorization = inspector.authorization() }
            DispatchQueue.main.async {
                if checkAuthorization { self.lastAuthorizationCheck = Date() }
                else if current.authorization != .missing { current.authorization = self.snapshot.authorization }
                self.apply(current)
                self.refreshing = false
                if self.pendingUserRefresh {
                    self.pendingUserRefresh = false
                    self.refresh(forceProbe: true, userInitiated: true)
                    return
                }
                if current.running && current.interfacePresent && (forceProbe || self.evidence?.isFresh(for: current) != true || Date().timeIntervalSince(self.lastProbeAt) >= 60) {
                    self.verify()
                } else { self.userRefreshing = false }
            }
        }
    }

    private func apply(_ current: ConnectionSnapshot) {
        if lastProcessKey != nil && !current.running {
            notice = current.devicePresent == false ? "设备已拔出，旧连接已释放。重新插入后即可再次连接。" : "联网后台已退出。点击「连接 LTE」可再次连接，无需退出软件。"
            noticeIsError = current.devicePresent != false
        }
        if current.process?.key != lastProcessKey { traffic = nil; sampler = TrafficSampler() }
        lastProcessKey = current.process?.key
        snapshot = current
        if let rx = current.rxBytes, let tx = current.txBytes, let key = current.process?.key {
            traffic = sampler.sample(key: key, uptime: ProcessInfo.processInfo.systemUptime, rx: rx, tx: tx)
        }
    }

    func verify() {
        guard !fixtureMode, !checking, !busy, snapshot.running, !snapshot.backendInterrupted, snapshot.interfacePresent else { return }
        checking = true
        let captured = snapshot
        DispatchQueue.global(qos: .utility).async {
            let inspector = MacInspector()
            let result = inspector.verify(captured)
            let current = inspector.collect()
            DispatchQueue.main.async {
                self.applyVerification(result, current: current)
            }
        }
    }

    func applyVerification(_ result: ConnectivityEvidence, current: ConnectionSnapshot) {
        checking = false
        userRefreshing = false
        lastProbeAt = Date()
        if notice == Self.pendingVerificationNotice { notice = "" }
        // Real connection changes still invalidate old proof, even when the
        // periodic refresh itself is visually quiet.
        guard !busy, result.fingerprint == current.fingerprint, current.fingerprint == snapshot.fingerprint else {
            evidence = nil
            return
        }
        evidence = result
    }

    func primaryAction() {
        guard !fixtureMode, !busy, primaryEnabled else { return }
        if readOnly { confirmHandoff(); return }
        if snapshot.authorization == .outdated && snapshot.running { confirmDisconnect(); return }
        if snapshot.authorization != .ready { authorize(); return }
        if snapshot.backendInterrupted && snapshot.process?.executable == RuntimePaths.current.executable {
            perform(snapshot.devicePresent == false ? .disconnect : .connect)
            return
        }
        switch phase {
        case .routeMismatch: confirmRepair()
        case .limited: refresh(forceProbe: true, userInitiated: true)
        default: snapshot.running ? confirmDisconnect() : perform(.connect)
        }
    }

    func confirmHandoff() {
        guard !fixtureMode, !busy, !observeOnly else { return }
        let before = MacInspector().collect()
        guard let target = DesktopHandoffPolicy.target(snapshot: before, currentUID: Int(getuid()), observeOnly: observeOnly) else {
            apply(before)
            notice = "当前程序状态已变化，请重新检测后再启用控制。"
            noticeIsError = true
            return
        }
        let alert = NSAlert()
        alert.messageText = "启用新版连接控制？"
        alert.informativeText = "将请求旧版 Magic Bay LTE 正常退出界面程序，联网后台继续运行。完成后可在新版设置权限、连接或管理 LTE；本次切换不会拨号或修改网络。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "退出旧版界面并启用")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let current = MacInspector().collect()
        guard DesktopHandoffPolicy.unchanged(before: before, after: current, currentUID: Int(getuid()), observeOnly: observeOnly),
              let app = NSRunningApplication(processIdentifier: target.pid),
              app.bundleIdentifier == "local.magicbay.lte",
              app.executableURL?.standardizedFileURL.path == URL(fileURLWithPath: target.executable).standardizedFileURL.path else {
            apply(current)
            notice = "旧版身份或连接已发生变化，已取消切换，请重新检测。"
            noticeIsError = true
            return
        }
        handingOver = true
        guard app.terminate() else {
            handingOver = false
            notice = "旧版暂未接受退出请求。请在旧版菜单栏选择「退出」，然后重新检测。"
            noticeIsError = true
            return
        }
        queue.async {
            let inspector = MacInspector()
            for _ in 0..<40 {
                let processes = inspector.processes()
                if processes.available && !processes.entries.contains(target) { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            var after = inspector.collect()
            after.authorization = inspector.authorization()
            DispatchQueue.main.async {
                self.handingOver = false
                self.apply(after)
                self.lastAuthorizationCheck = Date()
                if after.readOnly {
                    self.notice = "仍有其他控制程序运行。请在旧版菜单栏选择「退出」，然后重新检测。"
                    self.noticeIsError = true
                } else if !after.evidenceAvailable || before.process != after.process {
                    self.notice = "旧版界面已退出，联网状态发生了变化。请先重新检测连接。"
                    self.noticeIsError = true
                } else {
                    self.notice = after.authorization == .ready ? "新版控制已启用。可以连接或管理 LTE。" : "新版控制已启用。点击「\(self.primaryTitle)」完成首次设置后，即可连接或管理 LTE。"
                    self.noticeIsError = false
                    self.expanded = after.authorization != .ready
                }
                self.refresh(forceProbe: true)
            }
        }
    }

    func confirmDisconnect() {
        guard !fixtureMode, disconnectEnabled else { return }
        let inspector = MacInspector()
        var before = inspector.collect()
        before.authorization = inspector.authorization()
        guard before.process == snapshot.process, !before.readOnly,
              before.authorization == .ready || before.authorization == .outdated,
              ControllerPolicy.decide(action: "stop", apn: "", snapshot: before) == .stop else {
            apply(before)
            notice = "暂时无法确认连接身份或控制权限，请重新检测后再断开。"
            noticeIsError = true
            return
        }
        let alert = NSAlert()
        alert.messageText = "断开 LTE 连接？"
        alert.informativeText = "正在使用 LTE 的联网任务会中断。退出桌面程序可以保留连接；只有此操作会停止联网后台。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "断开 LTE")
        if alert.runModal() == .alertSecondButtonReturn { perform(.disconnect, expectedProcess: before.process) }
    }

    func confirmRepair() {
        guard !fixtureMode, !readOnly, !busy, snapshot.running else { return }
        guard snapshot.authorization == .ready else { authorize(); return }
        let alert = NSAlert()
        alert.messageText = "修复 LTE 网络路径？"
        alert.informativeText = "将系统默认路由和 LTE DNS 切回当前 LTE 接口，不重新拨号。代理和 VPN 的配置保持原状。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "修复路径")
        if alert.runModal() == .alertSecondButtonReturn { perform(.repair) }
    }

    func authorize() {
        guard !fixtureMode, !readOnly, !busy else { return }
        if snapshot.runtime?.directory == RuntimePaths.current.directory && snapshot.running {
            notice = "新版后台正在运行。请先断开 LTE，再更新联网组件。"
            noticeIsError = true
            return
        }
        let alert = NSAlert()
        alert.messageText = "设置 Magic Bay LTE 联网权限"
        alert.informativeText = "macOS 需要管理员授权来创建 LTE 网络。接下来会显示系统密码窗口。只安装本应用的限定联网组件；日常连接无需再次输入密码。此次设置不会自动拨号，也不会替换旧版组件。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "授权并安装")
        if alert.runModal() == .alertSecondButtonReturn { perform(.authorize) }
    }

    private func perform(_ action: Operation, expectedProcess: ProcessIdentity? = nil) {
        guard !fixtureMode, snapshot.evidenceAvailable, let token = coordinator.begin(action, readOnly: readOnly) else { return }
        if action == .connect && !ConnectionPolicy.validAPN(apn.trimmingCharacters(in: .whitespacesAndNewlines)) {
            coordinator.finish(token)
            expanded = true
            notice = "APN 只能包含字母、数字、点、短横线和下划线，长度为 1–100。"
            noticeIsError = true
            return
        }
        operation = action
        userRefreshing = false
        pendingUserRefresh = false
        notice = ""
        let chosenAPN = apn.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == .connect { UserDefaults.standard.set(chosenAPN, forKey: "lteAPN") }
        let installer = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/install-helper").path
        let user = NSUserName()
        let recoveryProcess = snapshot.backendInterrupted ? snapshot.process : nil
        queue.async {
            let inspector = MacInspector()
            let before = inspector.collect()
            let result: CommandResult
            if !before.evidenceAvailable {
                result = CommandResult(code: 1, output: "process_inventory_unavailable")
            } else if before.readOnly {
                result = CommandResult(code: 1, output: "another_controller: 状态已变化，已暂停操作。")
            } else if let expected = expectedProcess, before.process != expected {
                result = CommandResult(code: 1, output: "disconnect_state_changed: 连接身份已变化，已取消断开。")
            } else if let expected = recoveryProcess, action != .authorize,
                      (before.process != expected || !before.backendInterrupted) {
                result = CommandResult(code: 1, output: "recovery_state_changed")
            } else if action == .authorize {
                let command = Self.shellQuote(installer) + " " + Self.shellQuote(user)
                let source = "do shell script " + Self.appleScriptString(command) + " with administrator privileges"
                result = CommandRunner().run("/usr/bin/osascript", ["-e", source], timeout: 180)
            } else {
                let arguments: [String]
                switch action {
                case .connect: arguments = ["start", chosenAPN]
                case .disconnect: arguments = ["stop"]
                default: arguments = ["repair"]
                }
                result = CommandRunner().run("/usr/bin/sudo", ["-n", RuntimePaths.controller] + arguments, timeout: 90)
            }
            var after = inspector.collect()
            after.authorization = inspector.authorization()
            DispatchQueue.main.async {
                guard self.coordinator.finish(token) else { return }
                self.operation = nil
                self.apply(after)
                self.lastAuthorizationCheck = Date()
                self.evidence = nil
                self.noticeIsError = result.code != 0
                if result.code != 0 { self.notice = ConnectionPolicy.readableError(result.output) }
                else if action == .disconnect {
                    self.noticeIsError = after.running
                    self.notice = after.running ? "后台仍在运行，尚未确认断开。请重新检测。" : "LTE 已断开。"
                } else if action == .authorize {
                    self.noticeIsError = after.authorization != .ready
                    self.notice = after.authorization == .ready ? "联网权限已就绪。接下来可直接连接 LTE。" : "组件已安装，但免密码授权尚未验证通过。请重新设置权限。"
                } else { self.notice = Self.pendingVerificationNotice }
                if after.running && after.interfacePresent { self.verify() }
            }
        }
    }

    func copyDiagnostics() {
        guard !fixtureMode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(snapshot: snapshot, evidence: evidence), forType: .string)
        notice = "诊断摘要已复制（不包含 SIM 身份号码或原始 USB 日志）。"
        noticeIsError = false
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func appleScriptString(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}

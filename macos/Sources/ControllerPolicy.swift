import Foundation

enum ControllerDecision: Equatable {
    case startNew, restart, alreadyRunning, repair, stop, alreadyStopped, refuse(String)
}

enum ControllerPolicy {
    static func decide(action: String, apn: String, snapshot: ConnectionSnapshot) -> ControllerDecision {
        guard ["start", "repair", "stop"].contains(action) else { return .refuse("unsupported_action") }
        guard snapshot.evidenceAvailable else { return .refuse("process_inventory_unavailable") }
        let apps = snapshot.competingApplications.filter { ConnectionPolicy.isDesktopApplication($0.executable) }
        if apps.contains(where: { URL(fileURLWithPath: $0.executable).lastPathComponent == "MagicBayLTE" }) || apps.count > 1 {
            return .refuse("another_controller: 请先退出其他 Magic Bay 桌面程序。")
        }
        if snapshot.helperCount > 1 { return .refuse("multiple_helpers: 检测到多个 USB 控制进程。") }
        if !snapshot.running && snapshot.helperCount > 0 { return .refuse("unknown_helper: 未确认后台身份，拒绝操作。") }
        if let process = snapshot.process {
            guard process.uid == 0, ConnectionPolicy.isManagedHelper(process.executable) || ConnectionPolicy.isLegacyBundleHelper(process.executable) else {
                return .refuse("unverified_process")
            }
        }
        switch action {
        case "start":
            guard ConnectionPolicy.validAPN(apn) else { return .refuse("invalid APN") }
            if snapshot.devicePresent == false { return .refuse("device_absent") }
            if snapshot.backendInterrupted {
                guard snapshot.devicePresent == true else { return .refuse("device_presence_unknown") }
                guard snapshot.process?.executable == RuntimePaths.current.executable,
                      snapshot.runtime?.directory == RuntimePaths.current.directory else { return .refuse("unverified_recovery_backend") }
                return .restart
            }
            return snapshot.running ? .alreadyRunning : .startNew
        case "stop":
            if let process = snapshot.process, process.executable != RuntimePaths.current.executable, !snapshot.routeMatches {
                return .refuse("legacy_route_changed: 旧版后台的网络路径无法确认。请在可断网时使用旧版关闭连接，或先将已识别的 LTE 路径切回后再断开。")
            }
            return snapshot.running ? .stop : .alreadyStopped
        default:
            guard snapshot.running, snapshot.runtime != nil, snapshot.interfacePresent,
                  snapshot.takeoverReady, snapshot.gateway != nil, snapshot.address != nil else { return .refuse("repair_requires_verified_interface") }
            return .repair
        }
    }
}

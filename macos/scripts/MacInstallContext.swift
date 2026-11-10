import Cocoa
import CoreGraphics

@main struct MacInstallContext {
    static func emit(_ values: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "quit", args.count == 4, let pid = Int32(args[1]) {
            let inventory = MacInspector().processes()
            guard inventory.available, let identity = inventory.entries.first(where: {
                $0.pid == pid && $0.uid == Int(getuid()) && $0.started == args[2] && $0.executable == args[3]
            }), let app = NSRunningApplication(processIdentifier: pid),
                ["local.magicbay.lte", "local.magicbay.lte.v2"].contains(app.bundleIdentifier ?? ""),
                app.executableURL?.standardizedFileURL.path == identity.executable else {
                emit(["quit_verified": false, "reason": "identity_mismatch"]); exit(75)
            }
            guard app.terminate() else { emit(["quit_verified": false, "reason": "termination_refused"]); exit(75) }
            for _ in 0..<100 {
                if app.isTerminated || !MacInspector().processes().entries.contains(identity) {
                    emit(["quit_verified": true, "pid": pid, "backend_touched": false]); return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            emit(["quit_verified": false, "reason": "application_still_running"]); exit(75)
        }
        if args.first == "restore", args.count == 3, let pid = Int32(args[1]),
           let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == args[2] {
            _ = app.activate(options: [])
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let front = NSWorkspace.shared.frontmostApplication
        let magic = MacInspector().processes().entries.filter {
            ["MagicBayLTE", "MagicBayLTE2"].contains(URL(fileURLWithPath: $0.executable).lastPathComponent)
        }.map { identity -> [String: Any] in
            let app = NSRunningApplication(processIdentifier: identity.pid)
            return ["pid": identity.pid, "uid": identity.uid, "started": identity.started,
                    "executable": identity.executable, "bundle": app?.bundleIdentifier ?? "",
                    "bundle_executable": app?.executableURL?.path ?? ""]
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let owners = rows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .prefix(5).map { ["pid": $0[kCGWindowOwnerPID as String] ?? 0,
                             "name": $0[kCGWindowOwnerName as String] ?? ""] }
        emit(["at": ISO8601DateFormatter().string(from: Date()), "helper_pid": getpid(),
              "front_pid": front?.processIdentifier ?? 0, "front_bundle": front?.bundleIdentifier ?? "",
              "front_name": front?.localizedName ?? "", "window_owners": owners, "magic_apps": magic,
              "modifier_held": !flags.intersection(modifiers).isEmpty,
              "mouse_held": CGEventSource.buttonState(.combinedSessionState, button: .left) ||
                  CGEventSource.buttonState(.combinedSessionState, button: .right),
              "gui_controller_started": false])
    }
}

import Cocoa
import Foundation
import Darwin

@main struct HotspotRecovery {
    static let fm = FileManager.default
    static var buildDirectory: URL { Bundle.main.bundleURL.deletingLastPathComponent() }

    static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NSError(domain: "HotspotRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: "恢复记录无法读取。"])
        }
        return value
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    static func scriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func recover() throws -> String {
        let pointerURL = buildDirectory.appendingPathComponent("current-session.plist")
        guard fm.fileExists(atPath: pointerURL.path) else { return "当前没有通过本工具启动的热点，无需恢复。" }
        let pointer = try read(pointerURL)
        guard let sessionPath = pointer["session"] as? String, let controlPath = pointer["control"] as? String,
              sessionPath.hasPrefix(buildDirectory.path + "/session-"),
              controlPath.hasPrefix(buildDirectory.path + "/control-session-") else {
            throw NSError(domain: "HotspotRecovery", code: 2, userInfo: [NSLocalizedDescriptionKey: "恢复目录不属于当前工具，未执行操作。"])
        }
        let control = URL(fileURLWithPath: controlPath)
        let statusURL = control.appendingPathComponent("status.plist")
        if let status = try? read(statusURL), status["state"] as? String == "restored" {
            return "热点已经关闭，原 LTE 连接与系统访问已通过恢复检查。"
        }
        let request = control.appendingPathComponent("restore.request")
        if !fm.fileExists(atPath: request.path) { try Data().write(to: request, options: .withoutOverwriting) }
        if let pid = (pointer["guard_pid"] as? NSNumber)?.int32Value {
            let exists = kill(pid, 0) == 0 || errno == EPERM
            if exists {
                for _ in 0..<80 {
                    if let status = try? read(statusURL), let state = status["state"] as? String {
                        if state == "restored" { return "热点已关闭，原 LTE 连接与系统互联网访问已恢复。" }
                        if state == "blocked" { break }
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        // If the independent guard is unavailable, a click still performs
        // local recovery through the normal macOS administrator dialog.
        let tool = buildDirectory.appendingPathComponent("magicbay-hotspotctl").path
        let shell = quote(tool) + " restore " + quote(sessionPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script " + scriptString(shell) + " with administrator privileges"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, String(decoding: output, as: UTF8.self).contains("rollback_verified=1") else {
            throw NSError(domain: "HotspotRecovery", code: 3, userInfo: [NSLocalizedDescriptionKey: "恢复未能通过检查，或系统授权被取消。请保留当前联网设备和恢复入口，回到助手继续诊断。"])
        }
        return "已通过本机恢复工具关闭热点，LTE 与系统互联网访问检查通过。"
    }

    static func main() {
        if CommandLine.arguments.contains("--check") {
            let exists = fm.isExecutableFile(atPath: buildDirectory.appendingPathComponent("magicbay-hotspotctl").path)
            print("recovery_tool_present=\(exists) gui_opened=0 system_changes=0")
            exit(exists ? 0 : 1)
        }
        let original = NSWorkspace.shared.frontmostApplication
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let progress = NSAlert()
        progress.messageText = "正在关闭热点并恢复上网"
        progress.informativeText = "恢复在本机执行，不需要互联网，也不需要输入代码。请等待结果。"
        progress.addButton(withTitle: "正在恢复…").isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            do { result = .success(try recover()) } catch { result = .failure(error) }
            DispatchQueue.main.async {
                app.stopModal()
                progress.window.orderOut(nil)
                let alert = NSAlert()
                switch result {
                case .success(let message): alert.messageText = "恢复检查完成"; alert.informativeText = message
                case .failure(let error): alert.messageText = "需要继续检查"; alert.informativeText = error.localizedDescription; alert.alertStyle = .warning
                }
                alert.addButton(withTitle: "知道了")
                alert.runModal()
                if original?.processIdentifier != getpid() { original?.activate(options: []) }
                exit(0)
            }
        }
        app.activate(ignoringOtherApps: true)
        progress.runModal()
        app.run()
    }
}

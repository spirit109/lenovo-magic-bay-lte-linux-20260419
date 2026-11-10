import Cocoa
import Foundation
import SystemConfiguration

@main struct ProxyCompatibilityApp {
    static var tool: URL { Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("magicbay-proxy-compat") }
    static func scriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func main() {
        if CommandLine.arguments.contains("--check") {
            let present = FileManager.default.isExecutableFile(atPath: tool.path)
            print("compatibility_tool_present=\(present) gui_opened=0 system_changes=0")
            exit(present ? 0 : 1)
        }
        let original = NSWorkspace.shared.frontmostApplication
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let alert = NSAlert()
        alert.messageText = "Magic Bay 代理兼容"
        alert.informativeText = "让 Magic Bay LTE 使用你已经开启的 FlClash 系统代理。切换到其他网络或关闭助手时，自动撤销兼容设置。不会重新拨号。\n\n首次启用和停止可能需要 macOS 管理员授权。"
        alert.addButton(withTitle: "启用兼容助手")
        alert.addButton(withTitle: "停止并恢复")
        alert.addButton(withTitle: "取消")
        app.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        let action = choice == .alertFirstButtonReturn ? "start" : "stop"
        let quoted = "'" + tool.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let command = quoted + " " + action
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", "do shell script " + scriptString(command) + " with administrator privileges"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let result = NSAlert()
        do {
            try task.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw NSError(domain: "ProxyCompatibility", code: 1) }
            result.messageText = action == "start" ? "兼容助手已启用" : "兼容设置已撤销"
            if action == "start", let data = try? JSONSerialization.jsonObject(with: output) as? [String: Any], data["state"] as? String == "active" {
                result.informativeText = "当前 LTE 已使用 FlClash 系统代理。助手会在本次登录期间自动跟随网络变化。"
            } else {
                result.informativeText = action == "start" ? "使用 Magic Bay LTE 时会自动生效。重启电脑后如需继续使用，请再次打开本工具。" : "系统恢复使用原有代理设置，LTE 连接保留。"
            }
        } catch {
            result.messageText = "操作未完成"
            result.informativeText = "系统授权可能已取消，或兼容助手未通过检查。请保留当前网络，回到助手继续诊断。"
            result.alertStyle = .warning
        }
        result.addButton(withTitle: "知道了")
        result.runModal()
        if original?.processIdentifier != ProcessInfo.processInfo.processIdentifier { original?.activate(options: []) }
    }
}

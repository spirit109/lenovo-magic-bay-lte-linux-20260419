import Foundation
import SystemConfiguration
import Darwin

@main struct CleanStopProxy {
    static func main() {
        guard geteuid() == 0, CommandLine.arguments.count == 2 else { exit(77) }
        let project = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath().path
        let key = "State:/MagicBayLTEProxyCompatibility/Status"
        guard let store = SCDynamicStoreCreate(nil, "MagicBayCleanProxyStop" as CFString, nil, nil) else { exit(78) }
        guard let status = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else {
            print("old_proxy_stopped=1 changed=0"); return
        }
        guard let pid = (status["pid"] as? NSNumber)?.int32Value,
              let started = status["started"] as? String, let path = status["executable"] as? String,
              (path.hasPrefix(project + "/dist/proxy-compat-") && path.hasSuffix("/magicbay-proxy-compat")) ||
                path == "/usr/local/libexec/magic-bay-lte-v2/magicbay-proxy-compat" else { exit(75) }
        let inspector = MacInspector()
        let inventory = inspector.processes()
        guard inventory.available, let identity = inventory.entries.first(where: {
            $0.pid == pid && $0.uid == 0 && $0.started == started && $0.executable == path
        }) else { exit(75) }
        guard kill(pid, SIGTERM) == 0 else { exit(75) }
        for _ in 0..<50 {
            if !inspector.processes().entries.contains(identity) &&
                SCDynamicStoreCopyValue(store, key as CFString) == nil {
                print("old_proxy_stopped=1 stopped_pid=\(pid)"); return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        exit(75)
    }
}

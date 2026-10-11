import AppKit
import ScriptingBridge
import TripwireCore

/// The URL of the front tab, if the frontmost app is a supported browser (D10).
/// Never launches a browser: it asks only the app that is already in front.
/// It asks that process by PID, not by bundle id (D19): a headless copy of the
/// same browser (a screenshot job) would otherwise take the query.
enum ActiveTab {
    /// The scripting key of the front tab, per browser.
    private static let tabKey: [String: String] = [
        "com.brave.Browser": "activeTab",
        "com.google.Chrome": "activeTab",
        "company.thebrowser.Browser": "activeTab",
        "com.apple.Safari": "currentTab",
    ]

    /// Made once per process: tripwire asks every second.
    private static var apps: [pid_t: SBApplication] = [:]

    /// The front browser's name, for the menu ("Watching Brave").
    static var browserName: String? {
        NSWorkspace.shared.frontmostApplication?.localizedName?.replacingOccurrences(of: " Browser", with: "")
    }

    /// One read of the front tab. `.failed` means a window is open but no URL came back (D20).
    static func read() -> Detection.Read {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let id = front.bundleIdentifier,
              let key = tabKey[id] else { return .notBrowser }
        let pid = front.processIdentifier
        if apps[pid] == nil {
            apps = [:] // a new browser process: drop the old ones
            apps[pid] = SBApplication(processIdentifier: pid)
            apps[pid]?.delegate = errors
        }
        // An Apple event error (no Automation access, a lost connection) gives empty
        // results, not a throw. The delegate catches it, so it counts as failed.
        errors.failed = false
        let windows = apps[pid]?.value(forKey: "windows") as? SBElementArray
        let count = windows?.count ?? 0
        if errors.failed || windows == nil { return .failed }
        guard count > 0, let window = windows?.firstObject as? SBObject else { return .noWindow }
        let url = (window.value(forKey: key) as? SBObject)?.value(forKey: "URL") as? String
        guard !errors.failed, let url, !url.isEmpty else { return .failed }
        return .url(url)
    }

    private static let errors = ErrorFlag()

    private final class ErrorFlag: NSObject, SBApplicationDelegate {
        var failed = false
        func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
            failed = true
            return nil
        }
    }
}

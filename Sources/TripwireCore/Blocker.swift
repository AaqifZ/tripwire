import Foundation

/// Hands the block to SelfControl. Tripwire never blocks anything itself.
public enum Blocker {
    public static let cli = "/Applications/SelfControl.app/Contents/MacOS/selfcontrol-cli"

    public static func isRunning() -> Bool {
        // The answer is the last output line; SelfControl also logs noise.
        run([cli, "is-running"]).split(separator: "\n").last?.hasSuffix("YES") ?? false
    }

    /// When the running block ends, or nil if no block is running.
    public static func endDate() -> Date? {
        guard isRunning() else { return nil }
        let out = run([cli, "print-settings"])
        guard let line = out.split(separator: "\n").first(where: { $0.contains("BlockEndDate") }),
              let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close
        else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: String(line[line.index(after: open)..<close]))
    }

    /// Starts a system-wide block of every watched site. Returns false on failure.
    @discardableResult
    public static func start(minutes: Int, stateDir: URL) -> Bool {
        if isRunning() { return true }
        let file = stateDir.appendingPathComponent("blocklist.selfcontrol")
        let plist: [String: Any] = ["HostBlacklist": Sites.blocklist, "BlockAsWhitelist": false]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: file)) != nil else { return false }
        let end = ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(minutes) * 60))
        let output = run([cli, "start", "--blocklist", file.path, "--enddate", end])
        return output.contains("Block successfully added") || isRunning()
    }

    private static func run(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

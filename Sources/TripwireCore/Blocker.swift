import Foundation

public struct ActiveBlock: Codable, Equatable {
    public let endDate: Date
    public let domains: [String]
    public let isAllowlist: Bool

    public init(endDate: Date, domains: [String], isAllowlist: Bool) {
        self.endDate = endDate
        self.domains = domains
        self.isAllowlist = isAllowlist
    }

    /// A blacklist is verified only when every required host is explicit and
    /// the block lasts for the full requested period. Allowlist semantics are
    /// deliberately treated as unknown rather than guessed.
    public func covers(requiredDomains: [String], until requiredEnd: Date) -> Bool {
        guard !isAllowlist, endDate >= requiredEnd else { return false }
        let actual = Set(domains.map(Self.normalize))
        return Set(requiredDomains.map(Self.normalize)).isSubset(of: actual)
    }

    private static func normalize(_ domain: String) -> String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

public enum BlockSnapshot: Equatable {
    case unavailable
    case failed(String)
    case inactive
    case active(ActiveBlock)

    public var endDate: Date? {
        guard case let .active(block) = self else { return nil }
        return block.endDate
    }
}

/// Hands blocking to SelfControl and verifies the result from its secured settings.
public enum Blocker {
    public static let cli = "/Applications/SelfControl.app/Contents/MacOS/selfcontrol-cli"
    /// Root-owned script installed by `scripts/root-setup.sh`. It starts a
    /// root-owned copy of SelfControl, whose authorization rights allow root,
    /// so a trip shows no password dialog. A dialog is a Cancel button for the
    /// person being blocked. The script accepts only an end date.
    public static let rootBlock = "/Library/Tripwire/tripwire-block"
    public static let sudo = "/usr/bin/sudo"
    public static let commandTimeout: TimeInterval = 15

    /// Reads both the running bit and the effective policy. `is-running` alone
    /// cannot prove that the four Tripwire sites are covered.
    public static func snapshot(cliPath: String = cli, timeout: TimeInterval = commandTimeout) -> BlockSnapshot {
        guard FileManager.default.isExecutableFile(atPath: cliPath) else { return .unavailable }
        switch ProcessRunner.run(executable: cliPath, arguments: ["print-settings"], timeout: timeout) {
        case let .completed(code, output, _):
            guard code == 0 else { return .failed("SelfControl settings exited \(code): \(diagnostic(output))") }
            return parseSettings(output)
        case let .timedOut(output, _):
            return .failed("SelfControl settings timed out: \(diagnostic(output))")
        case let .outputLimitExceeded(output):
            return .failed("SelfControl settings exceeded the output limit: \(diagnostic(output))")
        case let .failedToLaunch(reason):
            return .failed("SelfControl settings could not start: \(reason)")
        }
    }

    /// Starts only when no block exists. The returned snapshot is a fresh read,
    /// so command success is never treated as proof of enforcement.
    public static func ensure(until: Date, stateDir: URL, cliPath: String = cli,
                              sudoPath: String? = sudo, rootBlockPath: String = rootBlock,
                              timeout: TimeInterval = commandTimeout) -> BlockSnapshot {
        let before = snapshot(cliPath: cliPath, timeout: timeout)
        guard case .inactive = before else { return before }

        let file = stateDir.appendingPathComponent("blocklist.selfcontrol")
        let plist: [String: Any] = ["HostBlacklist": Sites.blocklist, "BlockAsWhitelist": false]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try data.write(to: file, options: .atomic)
        } catch {
            return .failed("Could not write the SelfControl blocklist: \(error.localizedDescription)")
        }

        let end = ISO8601DateFormatter().string(from: until)
        // No user-level fallback: its password dialog is a Cancel button for
        // the person being blocked (D26). A missing rule stays a visible failure.
        guard let command = unattendedCommand(end: end, sudoPath: sudoPath, rootBlockPath: rootBlockPath,
                                              timeout: timeout) else {
            return .failed("Unattended block rule missing. Run: sudo scripts/root-setup.sh install")
        }
        switch ProcessRunner.run(executable: command.0, arguments: command.1, timeout: timeout) {
        case let .completed(code, output, _):
            if code != 0 {
                // A concurrent start or a helper reply race can leave a real
                // block behind even when this process reports failure.
                let after = snapshot(cliPath: cliPath, timeout: timeout)
                if case .active = after { return after }
                return .failed("SelfControl start exited \(code): \(diagnostic(output))")
            }
        case let .timedOut(output, _):
            // The helper may have completed after Tripwire's deadline. Re-read
            // before reporting failure, because only effective state is proof.
            let after = snapshot(cliPath: cliPath, timeout: timeout)
            if case .active = after { return after }
            return .failed("SelfControl start timed out: \(diagnostic(output))")
        case let .outputLimitExceeded(output):
            let after = snapshot(cliPath: cliPath, timeout: timeout)
            if case .active = after { return after }
            return .failed("SelfControl start exceeded the output limit: \(diagnostic(output))")
        case let .failedToLaunch(reason):
            return .failed("SelfControl start could not launch: \(reason)")
        }
        return snapshot(cliPath: cliPath, timeout: timeout)
    }

    /// Returns the root start command when the sudo rule permits it. `sudo -l`
    /// checks the exact command and never prompts because of `-n`.
    public static func unattendedCommand(end: String, sudoPath: String? = sudo,
                                         rootBlockPath: String = rootBlock,
                                         timeout: TimeInterval = commandTimeout) -> (String, [String])? {
        guard let sudoPath, FileManager.default.isExecutableFile(atPath: rootBlockPath) else { return nil }
        guard case .completed(0, _, _) = ProcessRunner.run(executable: sudoPath, arguments: ["-n", "-l", rootBlockPath, end],
                                                           timeout: timeout) else { return nil }
        return (sudoPath, ["-n", rootBlockPath, end])
    }

    /// True when a trip can start a block with nobody at the keyboard.
    public static func canStartUnattended() -> Bool {
        unattendedCommand(end: ISO8601DateFormatter().string(from: Date().addingTimeInterval(60))) != nil
    }

    /// Parses the current OpenStep-style dictionary printed through NSLog.
    /// The output has a timestamp prefix before `{` and can contain log noise.
    public static func parseSettings(_ output: String) -> BlockSnapshot {
        guard let running = integerValue(named: "BlockIsRunning", in: output) else {
            return .failed("SelfControl settings did not contain BlockIsRunning")
        }
        guard running != 0 else { return .inactive }
        guard let allowlist = integerValue(named: "ActiveBlockAsWhitelist", in: output),
              let endText = scalarValue(named: "BlockEndDate", in: output),
              let endDate = parseDate(endText),
              let domains = arrayValue(named: "ActiveBlocklist", in: output)
        else { return .failed("SelfControl active settings were incomplete") }
        return .active(ActiveBlock(endDate: endDate, domains: domains, isAllowlist: allowlist != 0))
    }

    private static func integerValue(named name: String, in text: String) -> Int? {
        scalarValue(named: name, in: text).flatMap(Int.init)
    }

    private static func scalarValue(named name: String, in text: String) -> String? {
        guard let nameRange = text.range(of: name),
              let equals = text[nameRange.upperBound...].firstIndex(of: "="),
              let semicolon = text[equals...].firstIndex(of: ";") else { return nil }
        return text[text.index(after: equals)..<semicolon]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func arrayValue(named name: String, in text: String) -> [String]? {
        guard let nameRange = text.range(of: name),
              let open = text[nameRange.upperBound...].firstIndex(of: "("),
              let closeRange = text[open...].range(of: ");"), open < closeRange.lowerBound else { return nil }
        return text[text.index(after: open)..<closeRange.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: text)
    }

    private static func diagnostic(_ output: String) -> String {
        let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return "no output" }
        return String(clean.suffix(512)).replacingOccurrences(of: "\n", with: " ")
    }
}

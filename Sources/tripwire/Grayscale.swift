import Foundation

/// The minute-4 warning: the macOS Accessibility grayscale filter (D12).
/// Uses private UniversalAccess calls. `CGDisplayForceToGray` does nothing on
/// some macOS versions, and per-channel gamma tables cannot make gray.
/// If the calls are missing after an OS update, the warning is skipped and the block still works.
enum Grayscale {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess", RTLD_LAZY)
    private typealias SetFn = @convention(c) (Bool) -> Void
    private typealias IsFn = @convention(c) () -> Bool
    private static let setFn = handle.flatMap { dlsym($0, "UAGrayscaleSetEnabled") }.map { unsafeBitCast($0, to: SetFn.self) }
    private static let isFn = handle.flatMap { dlsym($0, "UAGrayscaleIsEnabled") }.map { unsafeBitCast($0, to: IsFn.self) }

    /// Marks that tripwire turned gray on, so a crash or restart can undo it.
    private static let flag = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tripwire/gray-on")
    private static var ours = false

    static var isAvailable: Bool { setFn != nil && isFn != nil }

    /// Turns gray on or off. Never turns off a grayscale filter that the user turned on.
    static func set(_ on: Bool) {
        guard let setFn, let isFn else { return }
        if on, !ours, !isFn() {
            setFn(true)
            ours = true
            FileManager.default.createFile(atPath: flag.path, contents: nil)
        } else if !on, ours {
            setFn(false)
            ours = false
            try? FileManager.default.removeItem(at: flag)
        }
    }

    /// At start-up: undo gray left on by a previous run that did not exit cleanly.
    static func recover() {
        guard FileManager.default.fileExists(atPath: flag.path) else { return }
        ours = true
        set(false)
    }
}

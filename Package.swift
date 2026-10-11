// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tripwire",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: the rule, site matching, the SelfControl call, the event log.
        .target(name: "TripwireCore"),
        // The daemon and CLI: event tap, active tab, run loop.
        .executableTarget(name: "tripwire", dependencies: ["TripwireCore"]),
        // Tests without XCTest (CLT-only machine): `swift run TripwireSelfTest`.
        .executableTarget(name: "TripwireSelfTest", dependencies: ["TripwireCore"]),
    ]
)

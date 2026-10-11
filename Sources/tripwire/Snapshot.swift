import AppKit
import TripwireCore

/// `tripwire snapshot <dir>`: draws the menu bar item and its menu offscreen, with sample
/// states, to PNG files. For the README images. It uses the same `MenuBar.look` as the
/// live item, so the pictures show what the code shows. It touches no live state.
enum Snapshot {
    static let scale: CGFloat = 3

    static func run(dir: String) {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A fixed sample time, so the pictures do not depend on when you run this.
        let now = Calendar.current.date(bySettingHour: 14, minute: 3, second: 0, of: Date()) ?? Date()
        let today = EventLog.Counts(trips: 0, passes: 2)
        let states: [(String, MenuBar.State)] = [
            ("window", .init(site: "x.com", secondsLeft: 252, blockMinutes: 90, watchingBrowser: "Brave", today: today)),
            ("warning", .init(site: "x.com", secondsLeft: 48, blockMinutes: 90, watchingBrowser: "Brave", today: today)),
            ("writing", .init(site: "linkedin.com", secondsLeft: 131, writing: true, blockMinutes: 90, watchingBrowser: "Brave", today: today)),
            ("block", .init(blockEnd: now.addingTimeInterval(87 * 60 - 1), watchingBrowser: "Brave",
                            today: .init(trips: 1, passes: 2))),
        ]
        for (name, state) in states {
            let look = MenuBar.look(state, now: now)
            write(bar(look), to: out.appendingPathComponent("bar-\(name).png"))
            write(menu(look), to: out.appendingPathComponent("menu-\(name).png"))
            print("wrote bar-\(name).png, menu-\(name).png")
        }
    }

    /// The status item as the menu bar draws it: SF Symbol, then the monospaced title.
    private static func bar(_ look: MenuBar.Look) -> NSView {
        let button = NSButton(title: look.title, image: NSImage(systemSymbolName: look.symbol, accessibilityDescription: "tripwire")!,
                              target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.font = MenuBar.buttonFont
        button.contentTintColor = .labelColor
        button.sizeToFit()
        let pad: CGFloat = 8, height: CGFloat = 24
        let view = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 2 * pad, height: height))
        button.setFrameOrigin(NSPoint(x: pad, y: (height - button.frame.height) / 2))
        view.addSubview(button)
        return view
    }

    /// The dropdown menu: the same lines, colors, and font as the live NSMenu.
    private static func menu(_ look: MenuBar.Look) -> NSView {
        let groups = [[(look.headline, true), (look.detail, false)], [(look.health, false), (look.today, false)]]
            .map { $0.compactMap { text, primary in text.map { NSTextField(labelWithAttributedString:
                NSAttributedString(string: $0, attributes: MenuBar.attributes(primary: primary))) } } }
        let lineHeight: CGFloat = 22, padX: CGFloat = 14, padY: CGFloat = 6, gap: CGFloat = 11
        let width = max(260, (groups.flatMap { $0 }.map { $0.fittingSize.width }.max() ?? 0) + 2 * padX)
        let height = CGFloat(groups.flatMap { $0 }.count) * lineHeight + 2 * padY + gap
        let view = MenuBackground(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height - padY
        for (i, group) in groups.enumerated() {
            if i > 0 {
                y -= gap
                let line = NSBox(frame: NSRect(x: padX, y: y + gap / 2, width: width - 2 * padX, height: 1))
                line.boxType = .separator
                view.addSubview(line)
            }
            for field in group {
                y -= lineHeight
                field.frame = NSRect(x: padX, y: y + (lineHeight - field.fittingSize.height) / 2,
                                     width: width - 2 * padX, height: field.fittingSize.height)
                view.addSubview(field)
            }
        }
        return view
    }

    private final class MenuBackground: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
    }

    private static func write(_ view: NSView, to url: URL) {
        let aqua = NSAppearance(named: .aqua)!
        view.appearance = aqua
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        aqua.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

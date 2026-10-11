import AppKit
import TripwireCore

/// One menu bar item, always there (D16). Created once, never removed.
/// - During a block: a lock and the minutes left (D13).
/// - During a window on a watched site: an hourglass and the time left before the verdict (D14).
///   A pencil replaces the hourglass once you type enough keys: this window will pass.
///   While you write (D17), a pencil and the clock stands still.
/// - Blind (D20): a warning sign. Tripwire cannot read the tab, so it is not counting.
/// - Otherwise: a plain hourglass. Always visible, always in the same spot.
/// The menu shows state, not instructions (D20): what happens next, whether tripwire
/// can see, and today's results. It never shows a key count: that would be a target to game.
/// No Quit item on purpose: this process is tripwire, and quitting it would be a one-click off switch.
enum MenuBar {
    struct State {
        var blockEnd: Date?
        var site: String?
        var secondsLeft: Double?
        var safe = false
        var writing = false
        /// nil in test mode: a trip blocks nothing.
        var blockMinutes: Int?
        var blindSince: Date?
        var blindBrowser: String?
        var watchingBrowser: String?
        var today = EventLog.Counts()
    }

    private static var item: NSStatusItem?
    private static var lastSymbol = ""
    /// Made once with the menu: AppKit throws if a menu item is added to a second menu.
    /// That exception, swallowed by the run loop, once froze the tick timer for good.
    private static var headline = NSMenuItem()
    private static var detail = NSMenuItem()
    private static var health = NSMenuItem()
    private static var todayLine = NSMenuItem()

    static let siteNames = "X, LinkedIn, Reddit, Instagram"
    static let buttonFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    /// What the item and its menu show for one state. Pure, so `tripwire snapshot` can draw it too.
    struct Look {
        var symbol = "hourglass", title = ""
        var headline: String?, detail: String?, health: String?
        var today = ""
    }

    static func look(_ s: State, now: Date = Date()) -> Look {
        let time = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
        var l = Look()

        if let end = s.blockEnd, end > now {
            let minutes = Int(ceil(end.timeIntervalSince(now) / 60))
            l.symbol = "lock.fill"
            l.title = minutes >= 60 ? " \(minutes / 60)h \(minutes % 60)m" : " \(minutes)m"
            (l.headline, l.detail) = ("Blocked until \(time(end))", siteNames)
        } else if let left = s.secondsLeft {
            let seconds = Int(ceil(left))
            let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
            let site = s.site ?? "Watched site"
            l.symbol = s.safe || s.writing ? "pencil" : "hourglass"
            l.title = " " + clock
            if s.writing {
                l.headline = "\(site) · clock paused while you write"
            } else if s.safe {
                l.headline = "\(site) · this window will pass"
            } else {
                (l.headline, l.detail) = ("\(site) · block in \(clock)",
                         s.blockMinutes.map { "Then: all 4 sites blocked for \($0) min" } ?? "Then: a trip is logged (test mode, no block)")
            }
        } else if let since = s.blindSince {
            l.symbol = "exclamationmark.triangle"
            (l.headline, l.detail) = ("⚠︎ Can't read \(s.blindBrowser ?? "the browser")'s tab since \(time(since))",
                     "Tripwire is not counting. Run: tripwire status")
        }
        l.health = s.blindSince != nil ? nil
            : s.watchingBrowser.map { "✓ Watching \($0)" } ?? "Watching \(siteNames)"
        l.today = "Today: " + s.today.summary
        return l
    }

    static func show(_ s: State) {
        let l = look(s)
        update(symbol: l.symbol, title: l.title)
        set(headline, l.headline, primary: true)
        set(detail, l.detail, primary: false)
        set(health, l.health, primary: false)
        set(todayLine, l.today, primary: false)
    }

    /// The attributes of one menu line. Shared with `tripwire snapshot`.
    static func attributes(primary: Bool) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: primary ? NSColor.labelColor : NSColor.secondaryLabelColor,
         .font: NSFont.menuFont(ofSize: 0)]
    }

    /// Disabled (nothing to click) but in normal colors, so the menu reads as information.
    private static func set(_ item: NSMenuItem, _ text: String?, primary: Bool) {
        item.isHidden = text == nil
        guard let text, item.attributedTitle?.string != text else { return }
        item.attributedTitle = NSAttributedString(string: text, attributes: attributes(primary: primary))
    }

    private static func update(symbol: String, title: String) {
        if item == nil {
            let new = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // A fixed name, so the menu bar (and menu bar managers) treat each new item as the same one.
            new.autosaveName = "tripwire"
            new.button?.imagePosition = .imageLeading
            new.button?.font = buttonFont
            let menu = NSMenu()
            menu.autoenablesItems = false
            for line in [headline, detail] { line.isEnabled = false; menu.addItem(line) }
            menu.addItem(.separator())
            for line in [health, todayLine] { line.isEnabled = false; menu.addItem(line) }
            new.menu = menu
            item = new
            say("menu bar item created (button: \(new.button != nil))")
        }
        // Only touch the button when something changed (this runs every second).
        if lastSymbol != symbol {
            item?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "tripwire")
            lastSymbol = symbol
        }
        if item?.button?.title != title { item?.button?.title = title }
    }
}

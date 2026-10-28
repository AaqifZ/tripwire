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
    typealias State = Presentation.State
    typealias Look = Presentation.Look

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
    static func look(_ s: State, now: Date = Date()) -> Look {
        Presentation.look(s, now: now)
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

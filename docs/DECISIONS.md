# Decisions

Each design decision has an ID. The code refers to these IDs (for example `D12`). A later decision can replace part of an earlier one. The earlier text stays, so you can see why the design changed.

## D1. One job, one rule
- **Decision:** Tripwire does one thing. It has no schedules, budgets, dashboards, or rule modes.
- **Why:** An earlier blocker with rule modes, planning windows, a night mode, a browser extension, and a native app became too complex to keep running.
- **Lesson:** Each rule is a surface for negotiation. Keep one rule.

## D2. The unit is behavior, not the site
- **Decision:** Detect doomscrolling. Do not block a site because of time on the site.
- **Why:** X and LinkedIn can be work tools. A site block removes the work and the trance together.

## D3. Keystrokes are the creation signal
- **Decision:** Typing is creation. Scrolls and clicks (likes) are consumption.
- **Why:** The signal is cheap, local, and private. It needs only counts.
- **Accepted risk:** Long reading for research gives a false positive. Keyboard mashing gives a false negative. Both are acceptable.

## D4. macOS level only, no browser extensions
- **Decision:** Detection and enforcement run at the OS level.
- **Why:** A user in the trance can disable an extension with one click.

## D5. Tripwire detects, SelfControl blocks
- **Decision:** Use the SelfControl CLI for the block. Do not build a blocker.
- **Why:** SelfControl blocks system-wide, survives a restart, and is difficult to stop during a block. It is open source.
- **How (tested with SelfControl 4.0.2):**
  - Start: `selfcontrol-cli start --blocklist <file.selfcontrol> --enddate <ISO8601 UTC>`
  - Check: `selfcontrol-cli is-running` prints `YES` or `NO` on its last line.
  - Blocklist file: a plist with `HostBlacklist` (an array of domains) and `BlockAsWhitelist` = false.
- **Password:** SelfControl asks for an admin password before its first block, to install its helper. Later blocks start with no dialog, so tripwire can start them unattended.

## D6. Initial thresholds
- **Decision:** Window = 5 minutes. Creation = 30 typed keys or more in the window. Block = 90 minutes.
- **Status:** First defaults. The event log (D18) holds the data to tune them.
- **Decision:** No warning before the block. Replaced by D12.

## D7. Watched sites
- **Decision:** x.com (and twitter.com), linkedin.com, reddit.com, instagram.com.
- **Out of scope:** YouTube. Watching is the legitimate use there, so the typing signal does not apply.

## D8. Story first
- **Decision:** Write the user-facing behavior (this README) before the code. The build must make the README true.

## D9. Swift for the detector
- **Decision:** Write tripwire in Swift as one SwiftPM package.
- **Why:** The event tap, the frontmost-app check, and browser scripting are native macOS APIs. Swift gives one small binary with no runtime to install.
- **Tests:** The tests are an executable target, `swift run TripwireSelfTest`, so they run with the Command Line Tools only (no XCTest).

## D10. Which browsers tripwire reads
- **Decision:** Read the active tab URL in Brave, Chrome, Arc, and Safari.
- **Why:** If only one browser is watched, a switch to another browser is an easy way around the rule.
- **Gap:** Firefox has no scripting query for the tab URL. The block still covers Firefox, because SelfControl blocks system-wide. Only the detection misses Firefox.

## D11. What "a window" is
- **Decision:** Tripwire counts only the time that a watched site is the active tab of the front browser. After 5 minutes of that time, it checks the typed keys from that time. Fewer than 30 is a trip. Otherwise a new window starts.
- **Decision:** If you leave the watched sites for 5 minutes, the window resets.
- **Decision:** Tripwire writes one line per window result to `~/.tripwire/events.log`: time, result, key count, scroll count, and the matched domain.

## D12. The screen goes gray at minute 4
- **Decision:** At 4 minutes on a watched site with fewer than 30 typed keys, the whole screen turns grayscale. Color returns at once if you leave the site or type 30 keys. At 5 minutes, the trip happens as before.
- **Why:** A dialog gives you something to negotiate with. Gray asks for nothing. It turns the last minute into "type or lose it." This replaces the "no warning" part of D6.
- **How:** The macOS Accessibility grayscale filter, through the private `UAGrayscaleSetEnabled` call.
- **Rejected:** `CGDisplayForceToGray` (no effect on recent macOS). Gamma tables (a per-channel table cannot make gray). A page-only gray through browser JavaScript (needs a browser setting, against D4).
- **Safety:** Tripwire turns gray off only if tripwire turned it on. It turns gray off when launchd stops it, and at start-up after a crash.
- **Risk:** A macOS update can remove the private call. Then the warning stops and the block still works.

## D13. Menu bar countdown during a block
- **Decision:** While a block runs, the menu bar shows a lock and the minutes left. `tripwire status` shows the same end time.
- **Why:** A glanceable signal that you pull fits better than a notification that pushes.
- **Decision:** The menu has no Quit item. The item belongs to the tripwire process, so Quit would be a one-click off switch (against D4).
- **How:** Tripwire is an accessory app (no Dock icon). It polls SelfControl for the block end every 30 seconds, so a block started outside tripwire also shows.

## D14. Menu bar countdown during a window
- **Decision:** When a window starts on a watched site, the menu bar shows an hourglass and the time left before the verdict (for example `4:12`). After 30 typed keys, a pencil replaces the hourglass: this window will pass.
- **Why:** The gray screen (D12) only warns in the last minute. The countdown shows the time left from the first second.
- **How:** One item does both jobs. A block takes priority. The clock pauses while you are away and keeps the time left.
- **Tick:** Tripwire ticks every second, so the countdown moves one second at a time. Each tick is one tab read from the front browser.

## D15. Heartbeat in `tripwire status`
- **Decision:** The daemon touches `~/.tripwire/heartbeat` every 10 seconds. `tripwire status` shows the age of the last beat. Older than 30 seconds shows `STOPPED or FROZEN`.
- **Why:** An exception can stop the tick timer while the process stays alive. launchd then still shows tripwire as running. Only proof of a recent tick can show the difference.
- **How:** The file modification time is the beat. The file holds no content.

## D16. The menu bar item is always there
- **Decision:** The item is created once at start-up and never removed. When neither D13 nor D14 applies, it shows a plain hourglass.
- **Why:** An item that appears and disappears gets a new position each time, and menu bar managers can hide it. One permanent item keeps one fixed place. This replaces the "shows nothing the rest of the time" part of D13.

## D17. Writing pauses the clock
- **Decision:** While you write, the window clock stands still and the screen never goes gray. Writing means one of two things:
  - 20 keys or more in the last 30 seconds, in any app.
  - The front tab is a post composer (LinkedIn `/sharing/compose` or `/post/new`, X `/compose/`, Reddit `/submit`).
- **Why:** People often draft a post in another app, then paste it into the composer. Keys typed in other apps did not count, and the clock kept running while you wrote.
- **How:** The menu bar shows a pencil and a still clock. The daemon log writes `writing: clock paused` and `stopped writing`. It also names the front app on each `off watched sites` line.
- **Window:** Writing does not reset a window. The keys for the verdict still count on the site only.
- **Risk:** Keyboard scrolling (j and k on X) at 40 keys per minute or more looks like writing.

## D18. Log the windows that end with no verdict
- **Decision:** When 5 minutes away closes an open window, tripwire writes an `abandon` line to `events.log`: keys, scrolls, on-site seconds, paused seconds, and the domain. Each `pass` and `trip` line also gets `paused=Ns`, the on-site time with the clock paused by writing (D17).
- **Why:** Short visits reset with no line, and paused time left no record. To tune the thresholds, the log must account for all of the time on watched sites.
- **Privacy:** Counts and seconds only, as in D11.

## D19. Ask the browser in front by PID
- **Decision:** Tripwire reads the tab URL from the process that is in front, by its PID (ScriptingBridge). It does not address the browser by its bundle ID.
- **Why:** A second, headless copy of the same browser (for example a screenshot job) can take a query sent by bundle ID. It then answers with its own tab, and tripwire misses the real one.
- **How:** `NSWorkspace.frontmostApplication` gives the PID. A headless browser never comes to the front, so it never takes the query.

## D20. A blind alarm, and a menu that shows state
- **Decision:** Tripwire is "blind" after 60 seconds of failed tab reads in a row, with a browser window in front. It then shows a warning sign in the menu bar, writes `BLIND` to `tripwire.err`, and `tripwire status` prints `detection: BLIND since <time>`. One good read clears it.
- **Why:** A fresh heartbeat (D15) proves that the tick runs, not that tripwire can see. A lost Automation grant or a browser update can make every read fail. The alarm catches all of these causes.
- **Menu:** The menu shows state, not instructions: the site, the time to the block, the cost ("Then: all 4 sites blocked for 90 min"), the browser tripwire watches, and today's results.
- **Not shown:** A key count such as "6 / 30 keys". It would be a target to game. Also no Quit, snooze, or settings item.

## D21. Only typing counts, and writing pauses 3 minutes at most
- **Decision:** Two changes:
  - A key counts only if it is typing. Space, tab, escape, arrows, page up and down, home, and end do not count. A key with cmd or ctrl held does not count.
  - Writing (D17) pauses the clock for 180 seconds at most per window. After that, the clock runs.
- **Why:** Keyboard navigation (space, arrows) and shortcuts (cmd+tab, cmd+w) pushed scroll-only windows over 30 keys, so they passed. An open composer page could also pause the clock with no limit.
- **How:** `Keys.isTyping` reads the keycode class and the cmd and ctrl flags. A real post has many typing keys and passes, so the cap does not stop real writing.
- **Privacy:** Tripwire reads the keycode only to sort navigation keys from typing. It stores no keycodes. It never reads the character.
- **Not done:** j and k still count. They are letters, and tripwire cannot see if a text field has focus.

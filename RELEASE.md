Tripwire 0.2.1 makes the block reliable. A trip now blocks with no password dialog, and Tripwire does not lose a trip.

## What changed
- **No password dialog.** SelfControl asks for an admin password at each block start, so the person being blocked could press Cancel. Run `sudo scripts/root-setup.sh install` one time. After that, a trip starts its block as root with no dialog. `tripwire status` shows `unattended blocks: yes`. See D26.
- **A trip stays pending until the block is verified.** Tripwire retries after a failed command or a restart. It checks the block's sites and end time. An unrelated SelfControl block does not count (D23).
- **Input goes to the right window.** A scroll on a background browser window counts for that window. Typing in another app earns no credit (D22).
- **Unknown activity is shown, not hidden.** If Tripwire cannot see the browser, the menu shows the failure and the countdown waits (D24).
- **Safer install.** The installer builds and signs before it stops the old version, and restores it after a failure (D25).

## Upgrade
    git pull
    scripts/install.sh
    sudo scripts/root-setup.sh install

Run `root-setup.sh install` again after a SelfControl update.

## Known limits
- An admin can unload the LaunchAgent or remove the root setup. The goal is friction, not impossibility.
- The gray warning uses a private macOS call that a macOS update can remove. The block still works.
- Tripwire cannot read Firefox tabs. The SelfControl block still covers Firefox.
- Long reading with no typing trips the block.

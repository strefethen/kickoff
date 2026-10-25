# Assessment: Chrome scripting spike

**Status:** pending — run with Steve present, Chrome free to open and close
windows, and nothing playing on the target display.
**Feeds:** `plans/current/bulletproof-chrome-setup.md`. Its acceptance waits
on these answers.
**Environment to record:**

- macOS version and Chrome version;
- display arrangement as reported by `Kickoff --monitors`;
- whether "Displays have separate Spaces" is on;
- the menu bar auto-hide setting.

## Questions

Each question needs a yes/no answer backed by captured output. Any "no"
returns the plan to Steve before acceptance.

1. **Split panes by tab id.** In a window created with `make new window`,
   pressing the AX split button should add exactly one tab id. Setting that
   tab's `URL` by id should load the right pane, and the left pane's id should
   load the left pane. Both must hold when the user has clicked the other
   pane first, which changes `active tab`.
2. **Script bounds.** `set bounds` should use the same top-left global
   coordinates as AX. Starting from a 1128 pt-tall last-used window on a Dell,
   a single `set bounds` should land exactly on
   `{{-1896, 49}, {1872, 1007}}` on Office (AirPlay). The same should hold for
   quad's two frames.
3. **Space departure signal.** Closing a full-screen window by script should
   be followed by a public, pollable signal that its Space has left the target
   display. The candidate: the closed window id is gone from both clients,
   and no on-screen Chrome window in `CGWindowListCopyWindowInfo` has bounds
   equal to the display's bounds. The signal must not depend on the menu bar
   reappearing, because an auto-hidden menu bar never does. After the signal,
   a new window should land on the display's desktop and be listed by AX.
   Repeat with menu bar auto-hide both on and off.
4. **Raise by index.** `set index of window id N to 1` should make that window
   front and main for quad. AX `kAXMainWindowAttribute` should agree.
5. **Cold start.** With Chrome quit, launch it the way `ChromeApplication`
   does and send `make new window` at once. Record:
   - the error codes until it succeeds (for example -600 or -609);
   - the time it takes;
   - whether any duplicate window appears;
   - when startup and restored windows appear, relative to the first
     successful Apple Event round-trip.
6. **Full screen elsewhere.** With a Chrome window full screen on a Dell and
   most recently used, `make new window` should appear on a normal desktop and
   not pull the Dell out of full screen. After `set bounds` onto Office, AX
   should list the new window.
7. **Permission API.** `AEDeterminePermissionToAutomateTarget` should report
   the not-yet-decided, granted, and denied states correctly for a signed
   local build. Reset first with `tccutil reset AppleEvents
   com.stevetrefethen.kickoff`.

8. **Busy target.** Kickoff should be able to tell when the target display is
   showing another app's full-screen window, for example Safari or QuickTime.
   A normal, non-full-screen window resized to exactly the display's bounds
   must not count as busy. The candidate: an on-screen window from
   `CGWindowListCopyWindowInfo` whose bounds equal the display's, confirmed
   by that app's AX window reporting `AXFullScreen` as true.

## Method and safety

- Probe scripts live outside the repo (for example `/tmp/kickoff-probe/`).
  They act only on windows they create and close them at the end.
- Windows that were open before the spike are listed at the start and
  confirmed unchanged at the end.
- Raw outputs go in `captures/chrome-scripting-spike-<date>/`, which is
  gitignored. This file keeps only the answers and a pointer.

## Findings

_Not run yet._

---
status: draft
epic:
created: 2026-10-24
revive-when:
---

# Bulletproof Chrome setup

**Seed (Steve, 2026-10-24, verbatim):**

> trying to run setup chrome on Office monitor can getting errors.
>
> I want to watch with two screens setup in chrome
>
> clearly browser setup needs to be essentially bulletproof otherwise the app is a fail

"Two screens" is read as the split layout (two panes) on the Office display.
That is the setup that failed in the field.

Decisions Steve made in the same session (answers to explicit questions):

1. Drive Chrome with AppleScript to create the window, set its frame in one
   call, and load URLs without focus or keystrokes. Keep Accessibility (AX)
   only for the split-view and full-screen buttons. Accept the one-time
   "Kickoff wants to control Google Chrome" permission prompt.
2. When a step does not verify, re-apply steps that are safe to repeat until
   they verify, within a time limit. On final failure, close the window this
   setup created and show the specific reason.
3. If a Kickoff layout is already on the target display: "Close the Chrome
   windows Kickoff created earlier on that display, then build the new
   layout. Your other Chrome windows are never touched."

## Outcome and non-goals

**Outcome.** Choosing **Set Up Chrome** produces the selected layout (single,
split, or quad) on the selected display every time, under the conditions a
real game day produces:

- any monitor size, including a 1920×1080 AirPlay display;
- Chrome already running or not;
- any size of last-used Chrome window, including one in full screen on
  another display;
- a previous Kickoff layout still full screen on the target display;
- the user clicking around while setup runs, including inside the setup
  window.

When setup truly cannot finish, it leaves none of its windows behind, names
the exact cause, and leaves a log that explains the run.

**Non-goals.**

- Browsers other than Google Chrome.
- Changing how Chrome is launched when it is not running (it opens its usual
  startup or restored windows).
- Changing ad detection or ad muting, beyond stopping and resuming it around
  setup as today.
- Navigating panes that are already open when the Website URL changes.
- Identifying windows created by Kickoff builds that predate this plan.

## User-visible workflows

**Prerequisite.** Setup requires macOS's "Displays have separate Spaces"
(the default), as full screen per display does today. If it is off, setup
fails with that cause.

**Permissions.** Setup starts Chrome if needed, then checks Automation
permission before it creates any Kickoff window. If macOS has not asked yet,
the system prompt appears once, and time spent on the prompt does not count
against the setup deadline. If permission is denied, setup stops before
creating a Kickoff window. The alert says to allow Kickoff under Privacy &
Security → Automation → Google Chrome.

The menu shows **Open Automation Settings…** whenever the latest permission
check reported denied or not yet decided. Kickoff runs that check at setup,
and on menu open while Chrome is running; it never prompts.

**Normal setup (single, split, or quad).** Ad muting pauses. Setup closes any
earlier Kickoff windows on the target display, then creates one new window
per pane row on that display. It loads the configured website into each pane,
creates split view where the layout needs it, and enters full screen for
single and split. Ad muting then resumes. The user may keep using other apps
or click in the setup window throughout. Nothing in setup requires Chrome to
be frontmost or a field to have keyboard focus.

**Re-running setup mid-game.** Windows that Kickoff created in the current
Chrome process and that are now on the target display close first, including
in full screen. This includes windows the user later navigated elsewhere, and
windows left behind by a failed run. Kickoff windows now on other displays,
and all non-Kickoff windows, stay open. Closing happens before building, as
decided, so a re-run that then fails leaves that display without a layout.

**Target display busy.** If the target display is showing a full-screen
window that Kickoff did not create in this Chrome process, setup fails before
creating anything. The alert asks the user to exit that full screen. Windows
from before a Chrome restart count as not created by Kickoff. The same applies
when the target display's full-screen window is any other app.

**Chrome restarted since the last setup.** Kickoff cannot identify windows
from an earlier Chrome process. Setup builds normally if the display allows
it. The completion status and the log then state that windows from the
earlier Chrome session could not be identified and were left open (open
decision D2).

**Transient trouble.** Within the setup deadline (open decision D3), setup
re-applies or re-reads: a frame that macOS adjusts, a page slow to finish
loading, Chrome still starting, or a window briefly reported invalid. The user
sees nothing beyond normal setup time.

**Failure.** Once the deadline is exhausted, or a non-retryable condition
occurs, setup closes every window the run created. Non-retryable conditions
are permission denied, display disconnected or changed, Chrome quit, owned
window closed by someone else, or target busy. The alert names the step and
the specific cause. If a window could not be closed, for example because a
site's leave-page prompt kept it open, the alert says so and the window stays
recorded for the next run's replacement. Ad muting resumes as today.

**Concurrent setups.** One setup runs at a time across the menu app and the
CLI. A second attempt fails at once and says another setup is running.

**Diagnosis.** Every setup run appends to a persistent log under
`~/Library/Logs/Kickoff/`. The log records the steps, the Apple Event and AX
operations issued with their results, the owned windows' ids and frames, and
the target display's geometry. It contains no titles or URLs of non-Kickoff
windows. If the log cannot be opened, setup fails with that cause rather than
running unlogged.

## Decision-relevant facts

- **Field failure 1** (Office, AirPlay, 1920×1080, visible height 1055):
  setup moved the new window before resizing it. The window had inherited a
  1128 pt height from the last-used Chrome window, so macOS clamped the move
  to the top of the visible area. Fixed for the current path in `4e4a7ea`.
  The class remains for any two-write AX frame change.
- **Field failure 2**, same display: the pre-keystroke recipient check
  failed. The cause was undetermined; `a4c5e3b` made the six checks report
  separately. Keystroke submission requires Chrome frontmost, the setup
  window focused, and the omnibox focused through every key event.
- Chrome's omnibox exposes only `AXPress` and `AXShowMenu` (read live,
  Chrome 156.0.8078.47). AX-only navigation cannot avoid synthetic
  keystrokes.
- Chrome 156's scripting dictionary has these relevant entries:
  - `make new window`;
  - window `id`, settable `bounds`, settable `index` (front-to-back order),
    `active tab`, and settable `active tab index`;
  - tab `id`, settable `URL` ("the url visible to the user"), and `loading`;
  - window `close`.
- While a Chrome window was entering full screen, Chrome's File menu reported
  no children. AX menu-driven window creation is unavailable during
  full-screen transitions.
- Synthetic keystrokes (`CAXNavigation`) are used only by setup's
  `ChromeAddressEntry`.
- `Info.plist` has no `NSAppleEventsUsageDescription`, and there is no
  entitlements file. Release builds use the hardened runtime, which blocks
  Apple Events without `com.apple.security.automation.apple-events`. Local
  builds do not use it, so only a release build proves packaging.
- `AEDeterminePermissionToAutomateTarget` needs the target running.
  `NSAppleScript` is main-thread-only, while setup runs on a background queue
  (`HuluOperationController.startSetup`).
- Setup logging today is `print` to stdout, which is discarded when the app
  is opened from Finder.
- Two failed field runs left orphan windows.
- The CLI maps `--setup` to split and `--setup-quad` to quad; there is no
  single mode. CLI setup does not pause the menu app's ad monitor.
- **Facts the spike assessment must establish before acceptance:** see
  `plans/assessments/chrome-scripting-spike.md`. They are:
  - tab-id addressing of split panes;
  - script `bounds` coordinates and clamping on AirPlay;
  - a public, observable signal that a closed full-screen window's Space has
    left the target display;
  - detecting another app's full-screen window on the target, as distinct
    from a normal window sized to the display;
  - window `index` raise;
  - Apple Event behavior during Chrome cold start.

## Architecture

**Owners.**

- **Chrome scripting client** (new, beside the AX client). It sends Apple
  Events directly from the setup queue, not through `NSAppleScript`, and is
  bound to the same Chrome pid as the AX client. Every send carries a timeout
  no longer than the remaining setup deadline. It publishes:
  - permission check and request;
  - create a normal window, returning its id;
  - window ids with bounds;
  - set bounds and raise (by `index`);
  - tab ids, with the active tab and `loading`;
  - set a tab's URL by tab id;
  - close a window by id.

  Its errors are classified: permission denied, process gone, process not
  ready, object gone, timeout, and other (with the code). Callers use it
  through a protocol, so tests use a fake.
- **Accessibility client** (existing). It keeps read-only tree inspection
  (finding the buttons, verifying split UI, reading each pane's loaded URL)
  and the split-view and full-screen button presses. Setup no longer uses it
  for menus, frames, focus, raise, or keystrokes.
- **Setup run coordinator** (`ChromeSetup`, extended). It owns everything that
  spans a run:
  - the cross-process setup lock;
  - the setup log session;
  - the deadline, with permission-prompt time excluded;
  - the target re-read after replacement;
  - replacement and busy-target detection;
  - the set of windows this run created;
  - cleanup and ownership-store writes.

  It passes the clients and the deadline into each per-window session.
- **Per-window session** (`ChromeLayout`). It sequences one owned window and
  holds no run-wide state. It loses its keystroke, menu, AX-frame, and AX
  raise code.
- **Ownership store** (new). It is persisted in Kickoff's application
  defaults and is the only new persisted contract. It records each owned
  window as soon as `make new window` returns: Chrome process identity (pid
  plus launch date), window id, and target display UUID. A record is cleared
  once its window is confirmed closed. A malformed store fails setup with that
  cause and is cleared, so the next run starts clean.
- **Setup log** (new). It appends structured lines to a size-bounded file with
  one rotated predecessor, and still echoes to stdout for the CLI.

**Owned-window identity.** A window is owned when this run's `make new window`
returned its id. The coordinator takes its "before" window-id snapshot only
after a successful Apple Event round-trip, so Chrome's startup and restored
windows are already listed. A timed-out `make` is never retried blind. The
coordinator polls window ids for a settle interval:

- exactly one new id is owned;
- no new id counts as "no effect", and `make` may be retried;
- several new ids fail the run as ambiguous.

In the ambiguous case the alert and log name the unidentified window ids that
may remain. Setup neither adopts nor closes windows it cannot prove it
created. The AX element for an owned window is the one that meets all three
conditions:

- not listed before this window's `make`;
- not already paired in this run;
- with a frame equal to the bounds just set by script.

Anything else keeps waiting within the deadline. This also keeps quad's two
same-frame windows distinct.

**Panes.** Panes are addressed by tab id, never by `active tab`. The first
pane is the window's only tab before split. The right pane is the one new tab
id after the split button. Load verification reads each pane's AXWebArea URL
through AX inspection and accepts it with the existing `acceptsLoadedURL`
rule, which handles redirects and rejects error pages. Tab `URL` and
`loading` are progress signals only.

**Setup sequence per owned window.** The order is:

1. create;
2. set bounds and verify;
3. pair with AX;
4. set the first pane's URL and verify it loaded;
5. press split where the layout needs it, and record the new tab id;
6. set the right pane's URL and verify both panes;
7. press full screen for single and split.

Quad measures each split window's insets, sets final frames by script,
verifies them, and raises the top window by script.

**Retry contract.** Operations fall into three classes:

- *Re-applied* operations: set bounds and close. They are repeated whenever a
  re-read shows the state is not reached.
- *Guarded* operations: set URL. It is re-issued only if, after a settle
  interval, the pane is neither loading nor showing an accepted URL.
- *Toggles and creations*: make window, split button, full-screen button.
  They are repeated only after a re-read proves the earlier attempt had no
  effect. For example: no new id, no new tab, or `AXFullScreen` false after
  settle.

"Process not ready" and "timeout" are retryable within the deadline. Setup
has no alternate path: no keystroke navigation, and no adoption of windows it
cannot prove it created.

**Replacement.** After locking and before creating windows, the coordinator:

1. looks up every record for the current Chrome process identity;
2. closes those whose windows are on the target display;
3. waits for the spike-established Space signal;
4. re-reads the target's visible bounds before computing frames.

It then checks for a busy target. Records for other process identities are
discarded and counted for the restart notice.

**Removals.** Removed: `ChromeAddressEntry`, the `CAXNavigation` target, the
AX menu/window-diff creation path, and the AX frame and raise paths,
including `4e4a7ea`'s logic. The step diagnostics `--prepare`, `--split`,
and `--fullscreen` exercise those removed paths and are retired. The CLI gains
a single-layout setup command beside `--setup` and `--setup-quad`.

**Packaging.** `Info.plist` gains `NSAppleEventsUsageDescription`. Release
signing gains the Apple Events entitlement. The README documents the
Automation permission and the separate-Spaces prerequisite.

**Required order** (after acceptance):

1. Setup log.
2. Scripting client, permission flow and menu item, packaging.
3. Run coordinator: lock, deadline, ownership store, cleanup.
4. Per-window sessions on the new clients for single, split, and quad.
5. Replacement and busy-target detection.
6. Removals, CLI single mode, README.
7. Soak tooling and the acceptance run.

## Verification and operational risks

**Automated.** Each ticket carries its own testing obligations. All tests run
with fakes for both clients and the store.

**Real hardware.** A soak script drives the CLI setup commands with the menu
app's ad muting off. It verifies each result through both clients and tears
down only owned windows. It also confirms that no non-Kickoff window's id or
bounds changed. Conditions:

- (a) a tall last-used Chrome window on another display;
- (b) Chrome not running at start (open decision D1);
- (c) an earlier Kickoff layout full screen on the target;
- (d) another app activated, plus clicks in the setup window's left pane,
  timed at step boundaries (after create, after split, during load);
- (e) a Chrome window full screen on the other display as the last-used
  window;
- (f) a non-Kickoff full-screen window on the target. The expected result is
  a busy-target failure with no window created.

**Risks.**

- *Closing user-repurposed windows* that Kickoff created: accepted by
  decision 3. Scoping to one Chrome process identity and the target display
  limits reach.
- *Leave-page prompts* block closing. The run reports it, and the window
  stays recorded.
- *Profile picker or restore prompts* at Chrome launch block Apple Events.
  These surface as timeouts with a specific cause, exposed by condition (b).
- *Permission attribution.* The CLI's Apple Events are attributed to the
  terminal, so the soak cannot prove Kickoff.app's permission flow or
  entitlement. Menu runs from a release build cover that.
- *Hardware-only gaps.* Deadline exhaustion and cleanup during a full-screen
  transition are proven with fakes only.

## System success condition

On Steve's Mac (Chrome 156 or later), the soak passes every scenario with
zero failures:

- **Matrix:** split and quad on Office (AirPlay 1920×1080), and single and
  split on one Dell U2723QE, each under conditions (a)–(e), five consecutive
  runs per scenario. Condition (f) is checked once per display and produces
  its specific failure.
- **Results:** each run ends in the expected layout. No window from this run,
  or recorded from an earlier run, remains on the target except the run's
  final layout. No non-Kickoff window's id or bounds changed.
- **Menu runs:** three runs of split on Office through the menu app from a
  `build-app.sh --release` build succeed. One is a first run after resetting
  Kickoff's Automation grant: the prompt appears once, and
  `codesign -d --entitlements` shows the Apple Events entitlement.
- **Permission denial:** denying Automation produces the specific alert and
  creates no Kickoff window.
- **Failure injection:** closing the owned window mid-run produces the
  specific alert and leaves no Kickoff window behind.
- **Evidence:** the soak's per-run results, setup-log excerpts for (f), the
  denial, and the injected failure, plus a screenshot of the final split
  layout on Office.

---

**Disposition:** Draft — open questions:

- **D1:** may the soak quit and relaunch Chrome repeatedly (condition (b)),
  and in which session?
- **D2:** confirm the Chrome-restart behavior (build, then report unidentified
  earlier windows).
- **D3:** setup deadline. 60 s is proposed; ad muting stays paused for up to
  that long on failure.

Acceptance also waits on the spike assessment, which needs Steve present and
not watching on the target display.

<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Kickoff app icon">
</p>

# Kickoff

[![CI](https://img.shields.io/github/actions/workflow/status/strefethen/kickoff/ci.yml?branch=main&style=for-the-badge&logo=github&label=CI)](https://github.com/strefethen/kickoff/actions/workflows/ci.yml?query=branch%3Amain)

Football weekends often mean several games you want to watch at once. Streaming a game or a show on your TV also means reaching for the mute button every time the ads start. Kickoff helps with both: put your games side by side and automatically quiet detectable ads.

Kickoff is a native macOS menu bar app that arranges Google Chrome into one, two, or four viewing panes on your chosen monitor, including a TV connected to your Mac. Choose the game or program in each pane, then let Kickoff handle ad muting on Hulu and Peacock (experimental).

- **Follow multiple games:** Watch two or four games at once without repeatedly switching tabs or arranging windows by hand.
- **Settle in for a show:** Use a single pane for a program on your monitor or connected TV.
- **Quiet the commercial breaks:** Kickoff mutes ads it can detect and restores audio after the ad marker clears. Ads still play, and ads without a detectable marker may remain audible.

![Four football games in Chrome](Resources/Screenshot.webp)

## Requirements

- macOS 14 or later
- Apple Silicon Mac
- Google Chrome with split view available
- Swift 5.9 or later when building from source

Before using Kickoff, enable [chrome://flags/#enable-tab-audio-muting](chrome://flags/#enable-tab-audio-muting) in Chrome and relaunch Chrome when prompted.

## Install

1. Download the latest `Kickoff-<version>-arm64.zip` from [GitHub Releases](https://github.com/strefethen/kickoff/releases).
2. Unzip the download and move `Kickoff.app` to `/Applications`.
3. Open Kickoff, choose **Open Accessibility Settings…** from its menu, then enable Kickoff under **Privacy & Security → Accessibility** so it can arrange and control Chrome.

## Build and launch

```sh
git clone https://github.com/strefethen/kickoff.git
cd kickoff
./build-app.sh
open build/Kickoff.app
```

Kickoff permits one menu-bar instance per user. Launching another copy exits before starting a second ad monitor. The instance lock is released automatically when the app exits, including after a crash. Command-line diagnostics remain available while the app is running.

Maintainer release instructions are in [docs/releasing.md](docs/releasing.md).

## Use Kickoff

<img src="Resources/Menu.webp" width="385" alt="Kickoff menu with display selection, layout icons, website URL, and Ad Muting enabled">

1. Open Kickoff’s menu and choose a **Display**.
2. Choose a **Layout**: single, split, or quad.
3. Use **Edit Website…** to change the URL shown in the menu.
4. Choose **Set Up Chrome**.

Kickoff uses the selected monitor for future setup runs. If that monitor is unavailable, it chooses an available monitor without replacing the saved preference.

Changing the Website URL affects the next setup run. It does not navigate Chrome panes that are already open.

Ad Muting defaults to On and keeps your selection through runtime errors. Confirmed paused Peacock playback waits normally and resumes monitoring when playback starts. When active playback lacks tab-audio controls, Kickoff checks normally for up to 30 seconds, then checks once every 30 seconds until controls return. Invalid bindings or audio action/readback failures stop monitoring and show an explicit Retry Ad Muting command while keeping On selected. Audio actions require freshly verified controls; incomplete scans never count toward restoration.

## Tests

```sh
swift test
```

## License

[MIT](LICENSE)

# OmniHub

**English** | [简体中文](README.zh-CN.md)

A menu bar suite for macOS. Screenshots, pinned images, clipboard history, Now Playing, to-dos, an SSH-capable terminal and a system monitor, all reachable from one floating dock.

- Native Swift and AppKit, no third-party dependencies
- Universal binary (Apple Silicon and Intel), macOS 14 or later
- About 9 MB installed
- English and Simplified Chinese interface: **Settings → General → Language** (English by default; takes effect after a restart)
- Checks for new versions by itself (at launch and every six hours) and offers to download and install them; while one is out, an **Update** button shows on the card, in the menu bar menu and in **Settings → General**

## Features

**Floating dock.** A small ball that stays where you drop it. Hover over it to open a card next to it; the card grows out of the ball and folds back when the pointer leaves. While media plays, the ball stretches into a pill with the spinning cover and a level meter, and (with Song and lyrics) the lyric being sung, held until the next line rolls up slowly from below; the song's name shows only while there is no lyric. The card keeps Home, Terminal, Shelf and Clipboard; its Settings icon opens Settings in the main window. A page opened with its shortcut stays in front until you close it; once you switch to another page, the card folds away when you click elsewhere. In the card, Tab / ⇧Tab move between fields and settings; Space or Return works the focused control.

**Menu bar.** A left click on the menu bar icon drops down a panel: what is playing on top, then CPU, memory, GPU, disk, battery, network speed and Keep Awake. A right click shows the menu, which starts with **Open Dashboard**.

**Main window (Dashboard).** Open Dashboard (from the panel, the menu or the Dock icon) opens an ordinary window with every page down the left: Home, Activity, Agenda, Terminal, Shelf, Clipboard and Settings. A page is shown in one place at a time: opening it in the window takes it from the card, and it comes back when the card folds. Settings opens on a list of its topics (the page list stays on the left); a topic opens its settings, and Back returns to the list. The window opens on the screen the pointer is on.

**Help.** The **?** at the bottom left of the main window (⌘?) explains every feature, with a search that narrows the help to the topics mentioning your words.

**Screenshots.**
- Capture with window detection, a magnifier and annotations with undo and redo: frames (rectangle or ellipse), arrows, pen, text, and a mosaic brush in three sizes to hide sensitive content. The chosen tool's options (shape, colour, brush size) open in a strip under the toolbar.
- Move or resize the selection before confirming.
- Copy, save, or pin the result. Save opens in the folder you saved to last.
- Scrolling capture stitches a long page while you scroll it yourself, or hold ↓ for a slow, steady scroll (↑ / ↓ step one notch).

**Pins.**
- Float any screenshot or clipboard image above every window.
- Zoom with scroll or pinch, and select the text in the image with Live Text.

**Clipboard.**
- Keeps a history of everything copied in any app, with favourites that you can reorder and that are never evicted.
- Skips content that password managers mark as concealed.

**Shelf.**
- Drop files on the ball to keep a copy for later, then drag them out wherever you need them.
- After a drop the Shelf card comes to the front and stays open until you close it; this can be turned off in Settings.
- Items expire after a configurable number of days (7 by default).

**Now Playing.**
- Cover, title, lyrics and a seekable progress bar.
- Play mode and like controls.
- When music and a video play together, the music is shown and controlled first.
- For players that ignore remote commands (for example NetEase Cloud Music), OmniHub uses the player's own menu instead; this needs Accessibility.

**Agenda.** To-dos alongside a month calendar that reads your macOS Calendar events, with a history of completed items.

**Terminal.**
- A tabbed PTY terminal with SSH and Telnet profiles.
- SFTP browsing, uploads and downloads; the Downloads button shows a running transfer's progress.
- Local, remote and dynamic port forwarding; SOCKS5 and HTTP proxies.
- A credential vault stored in the macOS Keychain.

**Activity.**
- Live CPU, GPU, memory, disk and network speed graphs.
- Battery: charge, state, health, cycle count, temperature and power.
- Top apps by CPU or memory, with each app's helper processes counted under it.
- Keep Awake: stops the display from sleeping for 30 minutes, 1 or 2 hours, or until turned off (also in the menu bar menu).
- Local IP addresses and an optional public IP lookup.

**Appearance.**
- The card's background opacity can be lowered to show the blurred desktop behind it.
- The menu bar can show the buddy (still, or flapping faster as memory or CPU fills up) or the status icon, optionally with the network speed to its right (upload above, download below); the dock ball can show the logo or the status icon; the status icon can also be shown in the Dock.
- The status icon is a live icon laid out like the iPhone "Duo" status icon; OmniHub draws it with its own code. An open ring with a head at the top, a glyph in the middle and dots (or an arc) on the same circle at the bottom, so the whole reads as one round outline, each show what you pick (battery, CPU, memory, disk, Wi-Fi, network, volume).
- Battery on the ring: the charge as a figure on battery, a bolt while charging, a plug when plugged in and not charging or full (or the figure, if you prefer). On battery the ring keeps the default colour from 80 %, shading through yellow and orange to red at 20 % or less, and turns green only while charging; the bolt is green, the plug the default colour, the figure turns red at 10 % or less and yellow in Low Power Mode. A Mac without a battery shows the plug. A small amber coffee cup next to the figure on top (in the top right corner when no ring is shown) means Keep Awake is on.
- Colours: themes (Automatic, Aurora, Sunset, Mint, Sakura, Violet, Paper) or your own colour for the ring, middle, dots and background.

## Installation

### Homebrew

```bash
brew install --cask qhr992/tap/omnihub
```

The cask clears the download's quarantine flag, so the first launch is not blocked. OmniHub updates itself; `brew upgrade --greedy` updates it through Homebrew.

### Manually

1. Download `OmniHub-<version>.dmg` from [Releases](https://github.com/qhr992/OmniHub/releases).
2. Open it and drag **OmniHub** into **Applications**.
3. Open OmniHub. Releases are signed with a self-signed certificate and are not notarized, so macOS blocks the first launch:
   1. Click **Done** on the warning.
   2. Open **System Settings → Privacy & Security** and click **Open Anyway** next to OmniHub.

   Alternatively, run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/OmniHub.app
   ```

### Permissions

| Permission | Required for |
|---|---|
| Screen Recording | Screenshots, scrolling capture and pins (required) |
| Accessibility | Controlling players through their menus; scrolling with ↑ / ↓ during a scrolling capture (optional) |
| Calendars | Showing calendar events in Agenda (optional) |

Grant Screen Recording in **System Settings → Privacy & Security → Screen Recording**, then restart OmniHub. Permissions that are missing are shown in red in Settings.

## Default shortcuts

| Shortcut | Action |
|---|---|
| `⌘1` | Screenshot |
| `⇧⌘2` | Pin clipboard image |
| `⇧⌘V` | Clipboard |
| `` ⌃` `` | Terminal |
| `⇧⌘T` | Agenda |
| `⌃⌥A` | Activity |
| `⇧⌘O` | Show or hide the dock |
| `⇧⌘Space` | Play / pause |

Scrolling capture is started from the menu bar menu or the screenshot toolbar. Every shortcut can be changed or cleared in **Settings → Shortcuts**.

## URL scheme

A running instance can be driven with `omnihub://` links, for example from scripts or launchers:

| URL | Action |
|---|---|
| `omnihub://snip` | Screenshot |
| `omnihub://longsnip` | Scrolling capture |
| `omnihub://open/<page>` | Open a page: `clipboard`, `activity`, `tasks`, `terminal`, `shelf`, `settings` |
| `omnihub://toggle/dock` | Show or hide the dock |
| `omnihub://playpause` | Play / pause |
| `omnihub://pin` | Pin the clipboard image (`omnihub://unpin` closes all pins) |

## Building from source

Requires the Xcode Command Line Tools (`xcode-select --install`). No Xcode project is involved.

```bash
./build.sh              # builds build/OmniHub.app
./build.sh --install    # builds, installs to /Applications and launches
./test.sh               # capture pipeline, stitching and player selection tests
```

`Tools/setup-signing.sh` creates a local signing identity so that permissions survive rebuilds. Without it the build falls back to ad-hoc signing.

The boot animation and illustrations are generated from the sources in `Tools/boot-film/` (HyperFrames; rendering needs Node.js 22+ and ffmpeg).

## Data and privacy

| Data | Location |
|---|---|
| Clipboard history, to-dos, terminal profiles, shelf files | `~/Library/Application Support/OmniHub/` |
| Settings | UserDefaults domain `com.local.omnihub` |
| Passwords | Login Keychain, service `com.local.omnihub.vault`, one item for all of them (macOS asks once, and once again after an update) |

OmniHub makes network requests only to fetch lyrics (`music.163.com`, `lrclib.net`), to check for updates at launch and every six hours (the release feed and downloads on `github.com`; can be turned off in **Settings → General**) and, if you turn it on, to look up your public IP address (`api.ipify.org`).

## Known limitations

- Now Playing relies on the private MediaRemote framework, which a future macOS release may change.
- macOS delivers media commands only to the app that holds Now Playing. A player without it can be controlled only through its own menu, and only if it has the matching menu item.
- The terminal is not a full VT100 emulator; full-screen programs such as `vim`, `htop` and `less` do not render correctly.

## Uninstalling

```bash
pkill -x OmniHub
rm -rf /Applications/OmniHub.app ~/Library/Application\ Support/OmniHub ~/.omnihub
defaults delete com.local.omnihub
tccutil reset All com.local.omnihub
```

If you stored passwords in the vault, also delete the `com.local.omnihub.vault` entries in Keychain Access.

## License

- Source code: [MIT](LICENSE), Copyright (c) 2026 DillonQiu.
- Artwork is **not** covered by the MIT License and all rights are reserved. This includes the app icon, avatar, illustrations, boot animation, the characters Lan and the little blue bird, and the startup chime. See [ASSETS-LICENSE.md](ASSETS-LICENSE.md). Forks that are distributed must replace them.

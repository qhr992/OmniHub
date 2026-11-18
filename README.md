# OmniHub

**English** | [简体中文](README.zh-CN.md)

A menu bar suite for macOS. Screenshots, pinned images, clipboard history, Now Playing, to-dos, an SSH-capable terminal and a system monitor, all reachable from one floating dock.

- Native Swift and AppKit, no third-party dependencies
- Universal binary (Apple Silicon and Intel), macOS 14 or later
- About 9 MB installed

## Features

**Floating dock.** A small ball that stays where you drop it. Hover over it to open a card next to it; the card grows out of the ball and folds back when the pointer leaves. While media plays, the ball stretches into a pill with the spinning cover and a level meter. The dock gives access to every page: Home, Activity, Agenda, Terminal, Shelf, Clipboard and Settings.

**Screenshots.**
- Capture with window detection, a magnifier and annotations (rectangle, ellipse, arrow, pen, text) with undo and redo.
- Move or resize the selection before confirming.
- Copy, save, or pin the result.
- Scrolling capture stitches a long page while you scroll it yourself.

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
- SFTP browsing, uploads and downloads.
- Local, remote and dynamic port forwarding; SOCKS5 and HTTP proxies.
- A credential vault stored in the macOS Keychain.

**Activity.** Live CPU, GPU, memory and disk graphs, local IP addresses, and an optional public IP lookup.

## Installation

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
| Accessibility | Controlling players through their menus (optional) |
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

Scrolling capture has no default shortcut. Every shortcut can be changed or cleared in **Settings → Shortcuts**.

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
| Passwords | Login Keychain, service `com.local.omnihub.vault` |

OmniHub makes network requests only to fetch lyrics (`music.163.com`, `lrclib.net`) and, if you turn it on, to look up your public IP address (`api.ipify.org`).

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

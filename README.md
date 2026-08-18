# JgDo

A native macOS menu bar productivity app for window management, system monitoring, and clipboard history.

[![Release](https://img.shields.io/github/v/release/sovandara1607/jgdo-app?label=Latest%20Release&color=blue)](https://github.com/sovandara1607/jgdo-app/releases/latest)
[![License](https://img.shields.io/badge/license-proprietary-lightgrey)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014+-blue)](https://github.com/sovandara1607/jgdo-app/releases)
[![Swift](https://img.shields.io/badge/Swift-6-orange)](https://swift.org)
[![Xcode](https://img.shields.io/badge/Xcode-16+-blue)](https://developer.apple.com/xcode/)

---

## Download

### Recommended: Direct Download
[![Download .dmg](https://img.shields.io/badge/Download-JgDo-arm64.dmg-blue?style=for-the-badge&logo=apple)](https://github.com/sovandara1607/jgdo-app/releases/latest/download/JgDo-arm64.dmg)

**Requirements:** macOS 14 Sonoma or later (Apple Silicon or Intel)

### Installation Steps
1. **Download** the `.dmg` file from above
2. **Open** the `.dmg` file
3. **Drag** JgDo into your Applications folder
4. **Launch** JgDo from Applications
5. **Grant** Accessibility permission when prompted (required for window management)
6. **Optional:** Enable "Launch at Login" in Settings for auto-start

### Auto-Update
JgDo includes [Sparkle](https://sparkle-project.org/) for automatic updates. When a new version is available:
- A badge appears on the menu bar icon
- Click **Check for Updates** in the menu bar popover or Settings
- Updates are signed and verified for security

---

## Features

### Window Management
- **10 snap layouts** — left/right half, quadrants, thirds, maximize, center
- **Edge-gap tiling** — configurable padding between snapped windows and screen edges
- **⌘-drag snapping** — drag a window while holding ⌘ to snap into available space
- **Adjacent resize** — drag an edge to resize neighboring windows in lockstep
- **Snap preview overlay** — ghost preview shows where a window will land before release
- **Multi-monitor support** — works correctly across multiple displays

### App Switcher
- **⌥Space** — quick app switcher with search, arrow navigation, and dual-snap support
- **⌥S** — switch to the previous app
- Press ↩ to snap the selected app side-by-side with the current one

### System Dashboard
- **Status popover** — click the menu bar icon for a live system dashboard
- **CPU, Memory, Disk** — real-time usage with per-core breakdown
- **Network** — upload/download speed
- **Battery** — charge level and time remaining
- **Display & Sound** — brightness and volume sliders

### Clipboard History
- **⌥V** — clipboard history with text, images, and files
- **Search & pin** — find and pin frequently used clips
- **Paste-in-place** — paste directly into the frontmost app

### Workspaces
- **Save window arrangements** — capture your current layout and restore it later
- **One-click restore** — bring back all windows to their saved positions

### Keyboard Cleaning Mode
- **Lock keyboard** for screen cleaning — unlock with ⌘⌥⎋

### Workflow Insights
- **Focus tracking** — see where your time goes today
- **App pair suggestions** — snap two apps side by side when you bounce between them

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌥Space | Open app switcher |
| ⌥S | Switch to previous app |
| ⌥V | Open clipboard history |
| ⌃⌥←/→ | Snap window left/right half |
| ⌃⌥↑/↓ | Snap window top/bottom half |
| ⌃⌥C | Snap window centered |
| ⌃⌥M | Maximize window |
| ⌃⌥⎋ | Cancel / close overlay |

---

## Build from Source

### Prerequisites
- **Xcode 16** or later
- **macOS 14+** deployment target

### Build
```bash
git clone https://github.com/sovandara1607/jgdo-app.git
cd jgdo-app
xcodebuild -project JgDo.xcodeproj -scheme JgDo build
```

### Create Release Archive
```bash
xcodebuild -project JgDo.xcodeproj -scheme JgDo -configuration Release -archivePath build/JgDo.xcarchive archive
```

---

## Architecture

- **MVVM + Services** — Views are SwiftUI; window/panel plumbing is AppKit
- **SwiftData** — clipboard history, workspaces, and usage events
- **CGEvent tap** — global hotkey monitoring (never blocks input)
- **AX API** — window position/size manipulation

---

## Permissions

| Permission | Required By | Notes |
|------------|-------------|-------|
| Accessibility | Window management, hotkeys, cleaning mode | Prompted on first launch |
| Screen Recording | Window thumbnails (optional) | Only needed for visual previews |
| Login Item | Launch at startup | Configurable in Settings |

---

## Support

- **Issues:** [GitHub Issues](https://github.com/sovandara1607/jgdo-app/issues)
- **Discussions:** [GitHub Discussions](https://github.com/sovandara1607/jgdo-app/discussions)

---

## License

Copyright © 2024 Sovandara Rith. All rights reserved.

This is proprietary software. Unauthorized distribution is prohibited.

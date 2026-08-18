# JgDo

A native macOS menu bar productivity app for window management, system monitoring, and clipboard history.

Built with Swift · SwiftUI + AppKit · SwiftData · macOS 14+

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

## Requirements

- macOS 14 Sonoma or later
- Accessibility permission (for window management features)
- Screen Recording permission (optional, for window thumbnails)

## Installation

### Download
Download the latest `.dmg` from [Releases](https://github.com/sovandara1607/jgdo-app/releases).

### Auto-Update
The app includes Sparkle for automatic updates. Click **Check for Updates** in the menu bar popover or Settings.

### Build from Source
```bash
git clone https://github.com/sovandara1607/jgdo-app.git
cd jgdo-app
xcodebuild -project JgDo.xcodeproj -scheme JgDo build
```

**Note:** The project requires **Xcode 16+** with project format 100.

## Architecture

- **MVVM + Services** — Views are SwiftUI; window/panel plumbing is AppKit
- **SwiftData** — clipboard history, workspaces, and usage events
- **CGEvent tap** — global hotkey monitoring (never blocks input)
- **AX API** — window position/size manipulation

## Permissions

| Permission | Required By | Notes |
|------------|-------------|-------|
| Accessibility | Window management, hotkeys, cleaning mode | Prompted on first launch |
| Login Item | Launch at startup | Configurable in Settings |

## License

Copyright © 2024 Sovandara Rith. All rights reserved.

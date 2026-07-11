# JgDo — Architecture & Roadmap

A native macOS menu bar productivity app (window management, clipboard history,
system monitoring) in the spirit of OneMenu / Raycast / Magnet.
Swift 6 · SwiftUI + AppKit · SwiftData · macOS 15+ (built against Xcode 27).

## 1. Architecture

**Pattern:** MVVM + Services. Views are SwiftUI; window/panel plumbing is AppKit.
All singletons are `@Observable` and implicitly `@MainActor`
(`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); only CGEvent-tap callbacks are
`nonisolated`.

```
┌────────────────────────── AppDelegate (AppKit shell) ─────────────────────────┐
│ NSStatusItem · NSPopover (dashboard) · KeyablePanel ×2 (switcher, clipboard)  │
│ Settings NSWindow · workspace observer · hotkey wiring                        │
└──────┬────────────────────────────────────────────────────────────────────────┘
       │ callbacks / @Observable state
┌──────▼──────────────────────── Services ──────────────────────────────────────┐
│ HotkeyManager          CGEvent tap: ⌥Space ⌥S ⌥V ⌃⌥+keys                      │
│ WindowManagerService   CGWindowList fetch · AX focus/minimize/close/frames    │
│ WindowResizeService    snap layouts, edge gaps, dual-app tiling               │
│ LayoutEngine           multi-window builtin layouts                           │
│ WorkspaceService       save/restore whole window arrangements (SwiftData)     │
│ ClipboardService       pasteboard polling → history (SwiftData)               │
│ CleaningModeController full keyboard lock + countdown overlay                 │
│ MonitorControlService  CoreAudio volume · DisplayServices brightness          │
│ WorkflowInsightsService on-device usage analysis + suggestions                │
│ SystemMonitor          CPU/mem/disk/net/battery sampling (runs only when      │
│                        the popover is open)                                   │
└──────┬────────────────────────────────────────────────────────────────────────┘
┌──────▼─────────────── Persistence (SwiftData ModelContainer) ─────────────────┐
│ ~/Library/Application Support/JgDo/JgDo.store (in-memory fallback)            │
└───────────────────────────────────────────────────────────────────────────────┘
```

**Key AppKit decisions**
- `NSStatusItem` + `NSPopover`, **not** `MenuBarExtra` — MenuBarExtra has no
  programmatic toggle, which global hotkeys require.
- `KeyablePanel` (NSPanel overriding `canBecomeKey`) for the switcher and
  clipboard HUDs so text fields receive keystrokes without activating the app.
- Navigation keys are consumed by `NSEvent.addLocalMonitorForEvents` in the
  AppDelegate, so SwiftUI text fields never beep on ↑↓/↩.
- Coordinates: AX APIs use CG coords (top-left origin); NSScreen uses AppKit
  (bottom-left). Convert with `cgY = screens[0].frame.height - appKitFrame.maxY`.

## 2. File map (all in `JgDo/JgDo/`, auto-compiled via file-system-synced group)

| File | Role |
|---|---|
| `JgDoApp.swift` | Entry point, `AppSettings` keys |
| `AppDelegate.swift` | Shell: status item, popover, HUD panels, hotkey wiring |
| `HotkeyManager.swift` | Global CGEvent tap |
| `WindowManagerService.swift` · `WindowResizeService.swift` · `LayoutPreset.swift` · `WindowLayout.swift` · `WindowInfo.swift` · `SnapPreviewOverlay.swift` | Window engine |
| `Persistence.swift` | SwiftData models + container |
| `ClipboardService.swift` · `ClipboardHistoryView.swift` | Clipboard manager |
| `WorkspaceService.swift` · `WorkspacesTile.swift` | Workspaces |
| `CleaningMode.swift` | Keyboard cleaning mode |
| `MonitorControls.swift` | Volume/brightness service + tile |
| `WorkflowInsights.swift` | Usage tracking + suggestions |
| `SystemStatusService.swift` | System metrics |
| `ContentView.swift` | Popover dashboard + switcher HUD + design tokens |
| `SettingsView.swift` | Settings window (General/Shortcuts/Clipboard/About) |

## 3. Database schema (SwiftData)

- **ClipboardItem** — `kindRaw` (text/image/file), `text`, `imageData`
  (`.externalStorage`), `filePaths: [String]`, `createdAt`, `isPinned`,
  `sourceBundleID`, `sourceAppName`. Capped (default 200, pinned exempt).
- **Workspace** — `name`, `symbolName`, `createdAt`, `lastUsedAt`,
  `windows` (cascade delete).
- **WorkspaceWindow** — `bundleID`, `appName`, `x/y/width/height`
  (AppKit desktop coords), inverse `workspace`.
- **AppUsageEvent** — `bundleID`, `appName`, `timestamp`, `previousBundleID`
  (pair detection). Pruned after 14 days.

## 4. Permissions

| Permission | Used by | Flow |
|---|---|---|
| Accessibility | hotkeys, window moves, cleaning mode | Alert on launch → deep-link to System Settings; tap retries every 1.5 s until granted |
| (No sandbox) | window management requires it | `ENABLE_APP_SANDBOX = NO` |
| Login item | Settings → Startup | `SMAppService.mainApp` |

Screen Recording is **not** required yet — window titles come from CGWindowList;
it becomes necessary only for window *thumbnails* (see roadmap).

## 5. Performance budget

- Idle: no timers except 0.5 s pasteboard `changeCount` poll (µs-level work).
- SystemMonitor samples only while the popover is open.
- Window list refresh is diff-based (IDs compared before mutating state).
- Target: < 1 s launch, < 150 MB RAM, 0% idle CPU.

## 6. Roadmap

**Shipped (MVP+)** — window snapping (10 layouts + gaps + preview overlay),
builtin multi-window layouts, app switcher with dual-snap, system dashboard,
clipboard history (text/image/files, pins, search, paste-in-place),
workspaces (save/restore), keyboard cleaning mode, volume/brightness controls,
launch at login, settings window, focus insights.

**Next milestones**
1. **Window thumbnails** in switcher (ScreenCaptureKit; needs Screen Recording
   permission + onboarding flow).
2. **Custom shortcut recorder** in Settings (persist per-action key combos;
   HotkeyManager reads a user-editable map instead of hardcoded VKs).
3. **Visual layout editor** — drag-to-define grid zones, per-monitor profiles.
4. **Workspace polish** — app auto-launch ordering, per-Space assignment,
   quick-switch hotkeys (⌃⌥1…9).
5. **Widgets** — calendar/weather/pomodoro tiles in the popover (EventKit,
   WeatherKit, UserNotifications).
6. **DDC/CI external-monitor control** (brightness/contrast/input source over
   I²C — MonitorControl-style).
7. **Smarter insights** — focus-session recommendations, weekly report,
   layout auto-suggestions on pattern detection.

## 7. Testing strategy

- **Unit (XCTest target, to add):** layout frame math (`targetFrame` per
  `WindowLayout` × gap values), clipboard dedupe/trim/pin logic against an
  in-memory `ModelContainer`, insights usage/pair math with synthetic events.
- **Integration (manual today, XCUITest later):** AX resize on a scratch app,
  paste-in-place round-trip, cleaning-mode lock/unlock (⌘⌥⎋), multi-monitor
  workspace restore.
- **Regression checklist per release:** permission-not-granted paths, store
  migration (delete-and-retry fallback), Light/Dark, 2 displays, low battery.

## 8. Build notes

- The project file format (110) requires **Xcode 27**:
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project JgDo.xcodeproj -scheme JgDo build`
- New `.swift` files under `JgDo/JgDo/` compile automatically
  (`PBXFileSystemSynchronizedRootGroup`) — never edit the pbxproj to add files.
- SourceKit shows false "Cannot find type X in scope" errors per-file; trust
  `xcodebuild`, not single-file diagnostics.

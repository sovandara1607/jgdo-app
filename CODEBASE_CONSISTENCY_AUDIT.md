# JgDo — Codebase Consistency Audit

Scope: full read-through of `JgDo/` (120 Swift files, ~19.7k lines) and `JgDoTests/`.
Goal: find real duplication/inconsistency, not stylistic nitpicks. No code changed in this phase.

## Headline finding

This codebase is **already substantially consolidated**. There is one canonical
`WindowLayout` enum, one canonical shortcut→action table (`HotkeyAction` +
`ShortcutStore`), one canonical settings layer (`AppSettings`), one canonical
logging façade (`AppLog`), and the Command Palette / window switcher / hotkey
path all bottom out in the same `WindowResizeService`/`WindowManagerService`
calls. Prior work has clearly already done the big structural consolidation
the "Do Not Do This" section warns against re-breaking. The remaining issues
are narrower: a few duplicated leaf implementations, one dead file, one
logging straggler, and a couple of low-risk style inconsistencies.

Given that, this audit recommends a **small, surgical** Phase 3 rather than a
large refactor — consistent with the "smallest useful improvement" directive.

---

## Critical

None found. Core architecture (layout model, action dispatch, settings,
logging) is already unified — see "Already Consistent" below.

---

## High

### H1 — AX frame-setting duplicated in 3 places instead of the existing shared helper

**Files:**
- `JgDo/WindowManagerService.swift:175-186` (`applyFrame(_:to:on:)`)
- `JgDo/LayoutPreset.swift:139-149` (`LayoutEngine.applyAXFrame(_:to:on:)`)
- `JgDo/WorkspaceService.swift:265-282` (`apply(_:to:)`)

**Inconsistency:** `WindowManagerService.swift` itself already defines the
canonical helper for this exact operation, right below the duplicates:

```swift
// MARK: - Shared AX geometry helpers
// Used both by WindowResizeService (hotkey/preset snapping) and
// WindowDragController (⌘-drag snap + adjacent resize) so the raw AX
// position/size plumbing lives in exactly one place.
extension WindowManagerService {
    static func setAXFrame(_ frame: CGRect, of axWindow: AXUIElement) -> CGRect { … }
}
```

`WindowResizeService.apply(frame:to:screen:)` correctly calls
`WindowManagerService.setAXFrame(...)`. The three sites above don't — each
reimplements the same `AXValueCreate(.cgPoint...)` / `AXValueCreate(.cgSize...)`
/ `AXUIElementSetAttributeValue` dance inline, byte-for-byte identical logic,
just without the read-back that `setAXFrame` provides (which exists
specifically because "some apps clamp size to their own minimum").

**Why it matters:** this is precisely the "one layout should produce the same
geometry regardless of whether it is invoked from shortcut / command palette
/ workspace / layout overlay" principle the audit is centered on — for the
*application* half of geometry (not just the *computation* half, which is
already fine). A future fix to AX-frame-setting (e.g. handling a new AX
error code, or adding undo recording universally) has to be remembered in 4
places instead of 1. `WorkspaceService.apply` and `LayoutEngine.applyAXFrame`
also silently skip the "read back what was actually applied" step, so a
workspace restore or preset-tile placement can silently disagree with what
`axFrame(of:)` would report immediately after, in a way hotkey snaps don't.

**Canonical approach:** route all three through
`WindowManagerService.setAXFrame(_:of:)`.

### H2 — The same "dark-tinted, accent-bordered HUD card" chrome is copy-pasted in 4 files

**Files:**
- `JgDo/WindowActionHUD.swift:132-140` (cornerRadius 20)
- `JgDo/WindowLayoutSelectorOverlay.swift:325-333` (cornerRadius 26)
- `JgDo/LayoutPickerView.swift:63-71` (cornerRadius 22)
- `JgDo/WindowLayoutPartnerSearchView.swift:47-55` (cornerRadius 24)

**Inconsistency:** all four apply the exact same three-layer composition —

```swift
.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: N, style: .continuous))
.background(RoundedRectangle(cornerRadius: N, style: .continuous).fill(Color.black.opacity(0.18)))
.overlay(RoundedRectangle(cornerRadius: N, style: .continuous)
    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.25))
.shadow(color: .black.opacity(0.35-0.4), radius: N, y: N/2)
```

with only `N` (and the shadow's opacity, which barely varies: 0.35 vs 0.4)
differing per call site. The comments in three of these four files *say
outright* this is meant to be one shared visual family:

- `WindowActionHUD.swift`: "Same dark-tinted, accent-bordered 'system HUD'
  language as the ⌃⌥←/→ layout overlay's card ... so it should read as the
  same family of surface."
- `LayoutPickerView.swift`: "Same dark-tinted, accent-bordered chrome as the
  ⌃⌥←/→ layout overlay and its 'fill other side' search — same
  layout-picking domain."

So the *intent* is already "one design token," but the *implementation* is
four independent copies. `PanelChrome.swift` already holds the equivalent
canonical modifier for the *other* card family the app uses
(`GlassPopoverCard(cornerRadius:)` for menu-bar popovers) — this HUD-card
family just never got the same treatment.

**Why it matters:** exactly the "duplicate constants representing a shared
design behavior" case the brief calls out by name. Four copies means a
future tweak (e.g. adjusting the accent-border opacity for Increase Contrast)
requires four synchronized edits, and any diff review can't tell locally
whether radius differences are semantically intentional or just an editing
grab-bag artifact.

**Canonical approach:** add a `HUDCard` `ViewModifier` next to
`GlassPopoverCard` in `PanelChrome.swift`, parameterized by `cornerRadius`
(shadow radius/opacity derived the same way each site already derives them),
and migrate all four call sites to `.hudCard(cornerRadius: N)`.

---

## Medium

### M1 — Two different idioms for "boolean setting, defaults to true" in `AppSettings`

**File:** `JgDo/JgDoApp.swift`

Every one of these keys is *also* pre-registered via
`UserDefaults.standard.register(defaults: [...])` in `JgDoApp.init()` — so
the fallback value is stated twice, in two different places, in two
different styles:

```swift
// Style A — trusts the registered default (used by 3 properties):
static var dragSnapEnabled: Bool { UserDefaults.standard.bool(forKey: dragSnapEnabledKey) }
static var adjacentResizeEnabled: Bool { UserDefaults.standard.bool(forKey: adjacentResizeEnabledKey) }

// Style B — re-states the default inline, ignoring the registered one (used by ~13 properties):
static var magnetismEnabled: Bool {
    UserDefaults.standard.object(forKey: magnetismEnabledKey) as? Bool ?? true
}
// same pattern: fileSearchEnabled, dashboardShowCPU, dashboardShowMemory,
// smartLayoutsEnabled, pipEnabled, nlWorkspaceEnabled, windowActionHUDEnabled,
// placementPreviewEnabled, layoutSelectorOverlayEnabled, layoutSelectorDimEnabled,
// actionToastsEnabled, layoutSelectorApplyOnRelease (default false), lowBatteryAlertsEnabled
```

**Why it matters:** two sources of truth for the same default value. If a
developer changes the registered default in `init()` without noticing the
inline `?? true`/`?? false` restates it, the two silently disagree (Style B
wins, since `register(defaults:)` only supplies a fallback when nothing else
is found — but the discrepancy is invisible at the call site). Low risk
either way today because the values happen to match, but it's the kind of
drift that's easy to introduce later.

**Canonical approach:** since every one of these keys is already registered
in `init()`, standardize on Style A (`UserDefaults.standard.bool(forKey:)`,
trusting the registration) and delete the redundant inline fallback. One
setting (`favoriteAppBundleIDsKey`/`favoriteLayoutsKey`, string/set-backed)
is a different shape and is out of scope for this — it's not part of the
bool-default duplication.

### M2 — `LayoutEngine`/`BuiltinLayout` (multi-window grid presets) reimplements the edge-gap-inset geometry `WindowResizeService` already centralizes

**Files:** `JgDo/LayoutPreset.swift:54-104`, `JgDo/WindowResizeService.swift:170-260`

`BuiltinLayout.frames(on:)` computes its own half/thirds/quadrant math with
its own gap-inset arithmetic (`insetBy(dx: hg, dy: hg)`), separate from (and
textually similar to, but not sharing code with) `WindowResizeService`'s
`targetFrame(for:on:)` / `edgeFrame(for:fraction:area:hg:)`. It reads
`WindowResizeService.shared.edgeGap` for the gap value (so the *setting* is
shared) but not the *geometry function* itself.

**Why it matters:** this is the one place in the app where "Left Half"-style
geometry genuinely has two independent formulas — e.g. `BuiltinLayout
.split50_50` and a plain `WindowLayout.leftHalf` + `.rightHalf` pair compute
what should be identical tile geometry via two different code paths. In
practice they currently agree (both split the gap-inset visible frame in
half), but nothing enforces that going forward.

**Why this is Medium, not High:** unlike H1/H2, merging these isn't a
same-shape swap. `WindowResizeService` computes *one* window's frame given a
layout + fraction; `BuiltinLayout` computes a *list* of N frames for a
whole-screen grid, including 3-way and 70/30 splits `WindowLayout` has no
cases for at all. Forcing them through one function risks exactly the
"six protocols/factories" over-engineering the brief warns against, for a
problem that's currently only theoretical (no observed drift). Recommend
leaving as-is unless a concrete bug surfaces, or — if touched later —
extracting just the shared "split a rect into N gap-separated columns/rows"
math into a small pure helper both call, without unifying the two enums.

### M3 — `*Manager` naming used for 3 of 41 singletons; `*Service` is the established convention for the rest

**Files:** `JgDo/FloatingWindowManager.swift`, `JgDo/HotkeyManager.swift`, `JgDo/LicenseManager.swift`

20 domain singletons use `*Service` (`WindowResizeService`,
`WorkspaceService`, `ClipboardService`, `FileSearchService`, …). These three
use `*Manager` for what is, structurally, the same kind of role (a
`static let shared` singleton owning some domain's state/behavior). This is
the exact pattern the brief flags: "avoid mixtures ... when they perform
essentially the same responsibility."

**Recommendation:** do **not** rename. Per the brief's own rule ("rename
only where it materially improves consistency," "do not perform a complete
rewrite for cosmetic reasons"), renaming 3 widely-referenced singletons
(`HotkeyManager` alone is threaded through `AppDelegate`'s ~23 closure
properties) is a mechanical, non-functional change whose main effect is diff
noise, not clarity — nobody reading `HotkeyManager.live` is confused about
what it does. Documenting the inconsistency here is enough; revisit only if
one of these three gets substantially rewritten for other reasons anyway.

---

## Low

### L1 — One stray `print()` instead of the app's `AppLog` façade

**File:** `JgDo/UpdateService.swift:56`

```swift
print("Will install update: \(item.displayVersionString)")
```

Every other file logs through `AppLog.<category>` (`os.Logger`). This is the
single remaining `print(...)` call in production code (verified via
repo-wide search). Trivial, safe fix: `AppLog.general.info(...)` (no existing
`AppLog.updates` category; `.general` is the right home for a one-off
lifecycle note, matching how other one-off infrastructure logging uses it
today).

### L2 — Dead code: `WindowListViewModel.swift` is entirely unreferenced

**File:** `JgDo/WindowListViewModel.swift` (125 lines)

Verified: the identifier `WindowListViewModel` does not appear anywhere else
in `JgDo/` or `JgDoTests/` — not instantiated, not referenced by name, no
`@objc`/selector/NSCoding path that could hide a dynamic reference (it has
no `@objc` members and isn't `Codable`/`NSObject`-derived). Its
`groupedWindows`/`filteredWindows`/pin-toggling logic duplicates what
`CommandPaletteState.AppGroup` grouping and `HUDState`'s switcher already do
for their own surfaces — this looks like an earlier, superseded "window list"
screen. Safe to delete.

(Note for future dead-code passes: this project uses Xcode 16's
file-system-synchronized groups — `PBXFileSystemSynchronizedRootGroup` in
`project.pbxproj` — so file membership is automatic from the filesystem;
there is no separate "add to target" bookkeeping to worry about when adding
or removing files.)

### L3 — Wide spread of one-off `cornerRadius` literals (19 distinct values app-wide)

Not recommending action. Per the brief's own caution ("do NOT create a giant
constants file containing unrelated values," "avoid over-engineering tiny
one-off views"), most of this spread reflects genuinely different UI scales
(a 4pt chip vs. a 26pt HUD card are not "the same value that drifted"). The
one place this *was* a real shared-value duplication (H2's four HUD cards)
is called out above; the rest reads as ordinary per-component sizing, not
inconsistency.

### L4 — `DispatchQueue.main.async` (48 sites) vs `Task { @MainActor in ... }` (14 sites)

Mostly justified, not a real inconsistency: the majority of the
`DispatchQueue.main.async` sites are inside `nonisolated(unsafe)` CGEvent-tap
/ AX-observer callback contexts (`HotkeyManager`, `WindowDragController`)
that fire on the main run loop from a C callback outside Swift concurrency
checking — `Task { @MainActor }` there would add an actor hop for no benefit
and is what the existing code comments explicitly reason about avoiding.
`Task {}` is used for genuine async/await call chains elsewhere. One
`Task.detached` exists (single call site) — not investigated further; low
volume, low risk.

### L6 — A few feature-local settings live outside `AppSettings` with their own inline defaults

**Files:** `JgDo/WorkflowInsights.swift:14,20` (`workflowInsightsEnabled`),
`JgDo/ClipboardService.swift:11,42` (`clipboardEnabled`),
`JgDo/TipsStore.swift:10` (`tipsEnabled`), `JgDo/UpdateService.swift:91,110`
(raw string key `"autoCheckUpdates"`, not even a named constant).

These read/write `UserDefaults.standard` directly with their own inline
`?? true` fallback instead of going through `AppSettings`, and (unlike every
M1 case) are **not** pre-registered via `register(defaults:)` — so, unlike
M1, the inline fallback here is load-bearing, not redundant, and must not be
mechanically changed. Flagged for awareness only: if `AppSettings` is
extended later, these four are the natural next candidates to fold in
(`UpdateService`'s especially, since `"autoCheckUpdates"` is a bare string
literal rather than even a locally-named key constant) — but doing so wasn't
queued for this pass and isn't a safe drop-in the way H1/H2/L1/L2/M1 were.

### L5 — Flat file layout: all 120 source files live directly under `JgDo/`

No subfolders (`Assets.xcassets` aside). The brief's example target
structure (`App/`, `Core/`, `Features/`, `Shared/`) is explicitly framed as
"direction only... do NOT blindly reorganize." Given the size of this
codebase (120 files) a folder-per-domain split (window management,
shortcuts, workspaces, clipboard, search, permissions, settings) would
likely help navigation, and is now low-risk mechanically since this project
uses file-system-synchronized groups (moving a `.swift` file on disk is
enough — no `project.pbxproj` surgery). Recommending this be a **separate,
explicitly-requested pass**, not bundled into this consistency cleanup: it
touches every file's path/git history for zero behavior change, which the
brief's "do not combine unrelated refactors" rule argues against doing
opportunistically here.

---

## Already Consistent (verified, not just assumed)

Called out explicitly so Phase 3 doesn't accidentally "fix" things that are
already the canonical pattern:

- **Window layout model:** `WindowLayout` (`WindowLayout.swift`) is the one
  enum for single-window placements. `HotkeyAction.layout`,
  `CommandPaletteState.PaletteCommand.layout`,
  `WorkspaceCommand`/`RecentCommandsStore`, and the snap-preview overlay all
  reference this same type — confirmed no second "Left Half"-shaped enum
  exists for any of shortcuts / palette / preview / workspace restoration.
- **Window geometry computation:** `WindowResizeService.targetFrame`/
  `edgeFrame`/`cycledFrame` is the single source for what a layout's frame
  *is*, including edge-gap inset math. (H1 above is about *applying* an
  already-computed frame, not computing it twice.)
- **Action dispatch:** hotkey path (`HotkeyManager` → `AppDelegate` →
  `WindowResizeService.shared.resizeFrontmostWindow`/`.resize(app:to:)`) and
  Command Palette path (`AppDelegate.pickPaletteCommand` →
  `WindowResizeService.shared.resize(app:to:)`) verified to call the exact
  same methods — no parallel business logic.
- **Shortcuts:** one action enum (`HotkeyAction`), one combo type
  (`KeyCombo`), one storage key (`"shortcutMap"` in `ShortcutStore`), one
  conflict-detection function (`ShortcutStore.conflict(for:excluding:)`),
  one category grouping (`HotkeyAction.categories`) shared by Settings and
  the cheat sheet.
- **Settings:** one `AppSettings` enum, defaults registered once in
  `JgDoApp.init()`, typed accessors with clamped ranges throughout (M1 is a
  style-consistency nit within this system, not a second system).
- **Logging:** one `AppLog` enum of `os.Logger` categories; only one stray
  `print()` in the entire app (L1).
- **Singletons:** consistent `static let shared` + `private init()` pattern
  across all 41 singletons.
- **Reusable panel chrome:** `PanelChrome.swift`'s `PanelTheme` tokens and
  `panelCard()`/`GlassPopoverCard` modifiers are genuinely shared by 15+
  files — good existing precedent for how H2's fix should look.
- **Reduce Motion:** consistently gated via
  `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (AppKit-level
  fades) / `@Environment(\.accessibilityReduceMotion)` (SwiftUI) across every
  overlay/HUD that animates.

---

## Phase 2 — Refactor sequence for Phase 3

Ordered by the brief's stated priority (foundational duplication before UI
cleanup) and by risk (safest/most mechanical first, verified by full build +
test suite after each step):

1. **H1** — route `WindowManagerService.applyFrame`, `LayoutEngine.applyAXFrame`,
   `WorkspaceService.apply(_:to:)` through `WindowManagerService.setAXFrame`.
   Build + test after.
2. **L1** — swap the stray `print()` for `AppLog.general`. Build after.
3. **L2** — delete `WindowListViewModel.swift`. Build + test after (confirms
   nothing secretly depended on it).
4. **H2** — add `HUDCard` modifier to `PanelChrome.swift`; migrate the 4 call
   sites. Build after each file migrated (4 small steps), then a full visual
   sanity check that nothing changed (same colors/radii/shadows per site,
   just centralized).
5. **M1** — standardize the 13 Style-B settings accessors on Style A. Build +
   test after.

M2 and M3 are documented but intentionally **not** executed — see their
"why this is Medium" / "do not rename" reasoning above. L3–L5 are documented,
no action.

---

## Phase 3/4/5 — Execution record

All five queued items were applied, each followed by a full build
(`xcodebuild build`) and the full test suite (`xcodebuild test`) before
moving to the next — no step landed on top of a broken build.

1. **H1 done.** `WindowManagerService.applyFrame`, `LayoutEngine.applyAXFrame`
   (`LayoutPreset.swift`), and `WorkspaceService.apply(_:to:)` now all call
   `WindowManagerService.setAXFrame(_:of:)` instead of reimplementing the
   `AXValueCreate`/`AXUIElementSetAttributeValue` pair inline. One geometry-
   application path app-wide.
2. **L1 done.** `UpdateService.swift`'s stray `print(...)` is now
   `AppLog.general.info(...)`. (This surfaced a real, pre-existing latent
   bug independent of the audit: the file only imported `Foundation` and
   `Sparkle`, and this project builds with the `MemberImportVisibility`
   upcoming feature enabled, which requires the module that *defines* an
   API — `os`, for `Logger`'s string-interpolation privacy overloads — to be
   imported directly in every file that uses it, not just transitively via
   `AppLog`. Added `import os`.)
3. **L2 done.** Deleted `JgDo/WindowListViewModel.swift` (confirmed
   zero references anywhere in `JgDo/`/`JgDoTests/` before deleting; build
   and full test suite still pass after removal).
4. **H2 done.** Added `HUDCard` (`ViewModifier`) to `PanelChrome.swift`,
   next to the existing `GlassPopoverCard`, parameterized by `cornerRadius`/
   `shadowOpacity`/`shadowY` so each of the 4 migrated call sites
   (`WindowActionHUD`, `WindowLayoutSelectorOverlay`, `LayoutPickerView`,
   `WindowLayoutPartnerSearchView`) renders pixel-identical output to what
   it had before, via `.hudCard(cornerRadius:shadowOpacity:shadowY:)`.
5. **M1 done.** All 13 `AppSettings` boolean accessors that duplicated their
   `register(defaults:)` value inline now read
   `UserDefaults.standard.bool(forKey:)` directly, matching the style
   `dragSnapEnabled`/`adjacentResizeEnabled`/`showPerCoreCPU`/
   `customStatusIconTemplate` already used. One idiom for "boolean setting
   with a registered default" app-wide.

**Final verification:** clean `xcodebuild build` and `xcodebuild test` both
succeed on the fully-migrated tree; no `print(...)` remain in `JgDo/`; no
references to the deleted `WindowListViewModel` remain; no duplicate AX
position/size-setting code remains outside `WindowManagerService.setAXFrame`;
no duplicate HUD-card chrome remains outside `PanelChrome.HUDCard`.

Everything in Critical/High is resolved. Medium/Low items are intentionally
left as documented recommendations, not applied — per the brief's own
"small, reviewable refactors" and "do not rename for cosmetic reasons"
rules, none of them clears the bar of a safe, unambiguous, high-value
mechanical change the way H1/H2/L1/L2/M1 did.

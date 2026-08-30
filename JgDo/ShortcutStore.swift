import AppKit
import CoreGraphics
import os

// MARK: - Key combo

/// A recorded keyboard combo. `nonisolated`: values are read inside the
/// CGEvent-tap callback, outside the main actor.
nonisolated struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: Int64
    var command = false
    var option = false
    var control = false
    var shift = false

    func matches(code: Int64, flags: CGEventFlags) -> Bool {
        code == keyCode
            && flags.contains(.maskCommand) == command
            && flags.contains(.maskAlternate) == option
            && flags.contains(.maskControl) == control
            && flags.contains(.maskShift) == shift
    }

    var hasModifier: Bool { command || option || control || shift }

    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        return s + Self.keyName(for: keyCode)
    }

    init(keyCode: Int64, command: Bool = false, option: Bool = false,
         control: Bool = false, shift: Bool = false) {
        self.keyCode = keyCode
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    init(event: NSEvent) {
        keyCode = Int64(event.keyCode)
        command = event.modifierFlags.contains(.command)
        option = event.modifierFlags.contains(.option)
        control = event.modifierFlags.contains(.control)
        shift = event.modifierFlags.contains(.shift)
    }

    /// Display names for ANSI virtual key codes.
    static func keyName(for code: Int64) -> String {
        let names: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
            26: "7", 28: "8", 25: "9", 29: "0",
            24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";",
            42: "\\", 43: ",", 44: "/", 47: ".", 50: "`",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return names[code] ?? "Key \(code)"
    }
}

// MARK: - Actions

nonisolated enum HotkeyAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case toggleSwitcher
    case clipboardHistory
    case commandPalette
    case windowSwitcher
    case snapLeftHalf, snapRightHalf, snapTopHalf, snapBottomHalf
    case snapTopLeft, snapTopRight, snapBottomLeft, snapBottomRight
    case snapMaximize, snapCenter
    case shrinkWindow, growWindow
    case undoSnap
    case toggleAlwaysOnTop
    case moveToNextDisplay, moveToPreviousDisplay
    case toggleFocusMode
    case showCheatSheet
    case toggleScratchpad
    case parkFrontmostWindow
    case restoreAllParked
    case createSnapGroup
    case organizeWorkspace
    case floatFrontmostWindow
    case nlWorkspace
    case showLayoutPicker
    case layoutFillOtherSide

    var id: String { rawValue }

    var layout: WindowLayout? {
        switch self {
        case .snapLeftHalf:    return .leftHalf
        case .snapRightHalf:   return .rightHalf
        case .snapTopHalf:     return .topHalf
        case .snapBottomHalf:  return .bottomHalf
        case .snapTopLeft:     return .topLeft
        case .snapTopRight:    return .topRight
        case .snapBottomLeft:  return .bottomLeft
        case .snapBottomRight: return .bottomRight
        case .snapMaximize:    return .maximize
        case .snapCenter:      return .center
        default:               return nil
        }
    }

    var label: String {
        switch self {
        case .toggleSwitcher:   return "Open app switcher"
        case .clipboardHistory: return "Open clipboard history"
        case .commandPalette:   return "Open command palette"
        case .windowSwitcher:   return "Window Switcher (search + focus any window)"
        case .shrinkWindow:     return "Shrink window"
        case .growWindow:       return "Grow window"
        case .undoSnap:         return "Undo last snap/move"
        case .toggleAlwaysOnTop: return "Toggle Always on Top"
        case .moveToNextDisplay:     return "Move window to next display"
        case .moveToPreviousDisplay: return "Move window to previous display"
        case .toggleFocusMode:       return "Toggle Focus Mode"
        case .showCheatSheet:        return "Show shortcuts cheat sheet"
        case .toggleScratchpad:      return "Open scratchpad"
        case .parkFrontmostWindow:   return "Park frontmost window"
        case .restoreAllParked:      return "Restore all parked windows"
        case .createSnapGroup:       return "Create Snap Group from current windows"
        case .organizeWorkspace:     return "Organize Workspace…"
        case .floatFrontmostWindow:  return "Float frontmost window (Picture-in-Picture)"
        case .nlWorkspace:           return "Natural-Language Workspace…"
        case .showLayoutPicker:      return "Show Layout Picker"
        case .layoutFillOtherSide:   return "Swap other side with… (after ⌃⌥←/→)"
        default:                return layout?.rawValue ?? rawValue
        }
    }

    static let defaultCombos: [HotkeyAction: KeyCombo] = [
        .toggleSwitcher:   KeyCombo(keyCode: 49, option: true),                 // ⌥Space
        .clipboardHistory: KeyCombo(keyCode: 9, option: true),                  // ⌥V
        .commandPalette:   KeyCombo(keyCode: 49, command: true, option: true),  // ⌘⌥Space
        .windowSwitcher:   KeyCombo(keyCode: 13, option: true, control: true, shift: true),  // ⌃⌥⇧W
        .shrinkWindow:     KeyCombo(keyCode: 47, option: true, control: true, shift: true), // ⌃⌥⇧. (>)
        .growWindow:       KeyCombo(keyCode: 43, option: true, control: true, shift: true), // ⌃⌥⇧, (<)
        .snapLeftHalf:     KeyCombo(keyCode: 123, option: true, control: true), // ⌃⌥←
        .snapRightHalf:    KeyCombo(keyCode: 124, option: true, control: true),
        .snapTopHalf:      KeyCombo(keyCode: 126, option: true, control: true),
        .snapBottomHalf:   KeyCombo(keyCode: 125, option: true, control: true),
        .snapTopLeft:      KeyCombo(keyCode: 32, option: true, control: true),  // ⌃⌥U
        .snapTopRight:     KeyCombo(keyCode: 34, option: true, control: true),  // ⌃⌥I
        .snapBottomLeft:   KeyCombo(keyCode: 38, option: true, control: true),  // ⌃⌥J
        .snapBottomRight:  KeyCombo(keyCode: 40, option: true, control: true),  // ⌃⌥K
        .snapMaximize:     KeyCombo(keyCode: 36, option: true, control: true),  // ⌃⌥↩
        .snapCenter:       KeyCombo(keyCode: 8, option: true, control: true),   // ⌃⌥C
        .undoSnap:         KeyCombo(keyCode: 6, option: true, control: true),   // ⌃⌥Z
        .toggleAlwaysOnTop: KeyCombo(keyCode: 17, option: true, control: true), // ⌃⌥T
        .moveToNextDisplay:     KeyCombo(keyCode: 30, option: true, control: true, shift: true), // ⌃⌥⇧]
        .moveToPreviousDisplay: KeyCombo(keyCode: 33, option: true, control: true, shift: true), // ⌃⌥⇧[
        .toggleFocusMode:       KeyCombo(keyCode: 3, option: true, control: true),                // ⌃⌥F
        .showCheatSheet:        KeyCombo(keyCode: 44, option: true, control: true),                // ⌃⌥/
        .toggleScratchpad:      KeyCombo(keyCode: 45, option: true, control: true),                // ⌃⌥N
        .parkFrontmostWindow:   KeyCombo(keyCode: 35, option: true, control: true),                // ⌃⌥P
        .restoreAllParked:      KeyCombo(keyCode: 35, option: true, control: true, shift: true),   // ⌃⌥⇧P
        .createSnapGroup:       KeyCombo(keyCode: 5,  option: true, control: true),                // ⌃⌥G
        .organizeWorkspace:     KeyCombo(keyCode: 31, option: true, control: true),                // ⌃⌥O
        .floatFrontmostWindow:  KeyCombo(keyCode: 3,  option: true, control: true, shift: true),   // ⌃⌥⇧F
        .nlWorkspace:           KeyCombo(keyCode: 45, option: true, control: true, shift: true),   // ⌃⌥⇧N
        .showLayoutPicker:      KeyCombo(keyCode: 37, option: true, control: true, shift: true),   // ⌃⌥⇧L
        .layoutFillOtherSide:   KeyCombo(keyCode: 48, option: true, control: true),                // ⌃⌥⇥
    ]

    /// Shared grouping used by both the Settings → Shortcuts list and the
    /// cheat-sheet overlay, so the two never drift out of sync.
    static let categories: [(title: String, actions: [HotkeyAction])] = [
        ("Global", [.toggleSwitcher, .clipboardHistory, .commandPalette, .windowSwitcher, .showCheatSheet, .toggleScratchpad]),
        ("Window Snapping", HotkeyAction.allCases.filter { $0.layout != nil }),
        ("Resize Steps", [.shrinkWindow, .growWindow]),
        ("Undo", [.undoSnap]),
        ("Always on Top", [.toggleAlwaysOnTop]),
        ("Displays", [.moveToNextDisplay, .moveToPreviousDisplay]),
        ("Focus Mode", [.toggleFocusMode]),
        ("Window Parking", [.parkFrontmostWindow, .restoreAllParked]),
        ("Snap Groups", [.createSnapGroup]),
        ("Organize Workspace", [.organizeWorkspace]),
        ("Picture-in-Picture", [.floatFrontmostWindow]),
        ("Natural-Language Workspace", [.nlWorkspace]),
        ("Layout Picker", [.showLayoutPicker]),
        ("Layout Overlay", [.layoutFillOtherSide]),
    ]
}

// MARK: - Store

/// User-configurable shortcut map, persisted as JSON in UserDefaults.
/// A plain-array snapshot (`lookup`) is republished on every change so the
/// CGEvent-tap callback can match combos without touching the main actor.
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    private static let defaultsKey = "shortcutMap"

    /// Written only on the main thread; read from the tap callback (which the
    /// main run loop also drives — same pattern as `HotkeyManager.live`).
    nonisolated(unsafe) static var lookup: [(action: HotkeyAction, combo: KeyCombo)] = []

    private(set) var map: [HotkeyAction: KeyCombo]

    private init() {
        var merged = HotkeyAction.defaultCombos
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey) {
            do {
                let saved = try JSONDecoder().decode([HotkeyAction: KeyCombo].self, from: data)
                merged.merge(saved) { _, custom in custom }
            } catch {
                // Falls back to defaults — any custom keybindings the user
                // set are silently lost otherwise, so this is worth a log
                // even though there's no user-facing surface to report it
                // to at init time.
                AppLog.hotkeys.error("Couldn't decode saved shortcuts, falling back to defaults: \(error.localizedDescription, privacy: .public)")
            }
        }
        map = merged
        Self.lookup = merged.map { ($0.key, $0.value) }
    }

    func combo(for action: HotkeyAction) -> KeyCombo {
        map[action] ?? HotkeyAction.defaultCombos[action]!
    }

    func isDefault(_ action: HotkeyAction) -> Bool {
        map[action] == HotkeyAction.defaultCombos[action]
    }

    func set(_ combo: KeyCombo, for action: HotkeyAction) {
        map[action] = combo
        persist()
    }

    func reset(_ action: HotkeyAction) {
        map[action] = HotkeyAction.defaultCombos[action]
        persist()
    }

    func resetAll() {
        map = HotkeyAction.defaultCombos
        persist()
    }

    /// The action already bound to this combo, if any.
    func conflict(for combo: KeyCombo, excluding action: HotkeyAction) -> HotkeyAction? {
        map.first { $0.key != action && $0.value == combo }?.key
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(map)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            AppLog.hotkeys.error("Couldn't save shortcut changes: \(error.localizedDescription, privacy: .public)")
        }
        Self.lookup = map.map { ($0.key, $0.value) }
    }
}

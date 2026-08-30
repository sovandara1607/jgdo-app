import os

/// Centralized `os.Logger` categories, one per subsystem, so Console.app /
/// `log stream --predicate` can isolate JgDo's own logging from system
/// noise, and so call sites that used to swallow errors via a bare `try?`
/// have somewhere structured to report them instead. Subsystem matches the
/// app's bundle identifier.
enum AppLog {
    private static let subsystem = "lonewolf.JgDo"

    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let license = Logger(subsystem: subsystem, category: "license")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let workspace = Logger(subsystem: subsystem, category: "workspace")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let window = Logger(subsystem: subsystem, category: "window")
    static let general = Logger(subsystem: subsystem, category: "general")
}

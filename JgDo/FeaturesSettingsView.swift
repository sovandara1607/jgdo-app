import SwiftUI

/// One place listing every optional feature — same `AppSettings` keys used
/// elsewhere, just gathered together so it's easy to see what's on.
/// Turning something off here stops its background work too (each flag
/// already gates its service at the source, not just its UI).
struct FeaturesSettingsView: View {
    @AppStorage(AppSettings.magnetismEnabledKey) private var magnetism = true
    @AppStorage(AppSettings.fileSearchEnabledKey) private var fileSearch = true
    @AppStorage(AppSettings.smartLayoutsEnabledKey) private var smartLayouts = true
    @AppStorage(AppSettings.pipEnabledKey) private var pip = true
    @AppStorage(AppSettings.nlWorkspaceEnabledKey) private var nlWorkspace = true
    @AppStorage(AppSettings.dashboardShowCPUKey) private var dashboardCPU = true
    @AppStorage(AppSettings.dashboardShowMemoryKey) private var dashboardMemory = true
    @AppStorage(ClipboardService.enabledKey) private var clipboard = true
    @AppStorage(AppSettings.actionToastsEnabledKey) private var toasts = true
    @AppStorage(TipsStore.tipsEnabledKey) private var tips = true

    /// One switch for both dashboard gauges — they're really "the same
    /// feature" from a user's point of view.
    private var dashboardBinding: Binding<Bool> {
        Binding(
            get: { dashboardCPU || dashboardMemory },
            set: { dashboardCPU = $0; dashboardMemory = $0 }
        )
    }

    var body: some View {
        Form {
            Section("Core") {
                Text("Window Manager, Command Palette, and Workspaces are always on — the rest of JgDo depends on them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Optional Features") {
                Toggle("Window Magnetism", isOn: $magnetism)
                Toggle("File Search", isOn: $fileSearch)
                Toggle("Smart Layouts", isOn: $smartLayouts)
                Toggle("Picture-in-Picture", isOn: $pip)
                Toggle("Natural-Language Workspace", isOn: $nlWorkspace)
                Toggle("Menu Bar Dashboard", isOn: dashboardBinding)
                Toggle("Clipboard History", isOn: $clipboard)
                Toggle("Confirmation Toasts", isOn: $toasts)
                Toggle("Tips", isOn: $tips)
                Text("Turning a feature off stops its background work — no polling, no hotkeys, nothing left running.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

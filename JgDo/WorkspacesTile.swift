import SwiftUI
import AppKit
import SwiftData

/// Popover tile for saving and restoring window workspaces.
struct WorkspacesTile: View {
    @State private var service = WorkspaceService.shared
    @State private var newName = ""
    @State private var isNaming = false
    @State private var renamingID: PersistentIdentifier?
    @State private var renameText = ""
    @FocusState private var nameFocused: Bool
    @FocusState private var renameFocused: Bool

    var body: some View {
        MetricTile(icon: "square.grid.2x2", title: "Workspaces", value: "", progress: nil) {
            VStack(alignment: .leading, spacing: 8) {
                if service.workspaces.isEmpty && !isNaming {
                    Text("Save your layout to restore it later, or start from a template.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(service.workspaces, id: \.persistentModelID) { workspace in
                    if renamingID == workspace.persistentModelID {
                        renameField(workspace)
                    } else {
                        workspaceRow(workspace)
                    }
                }

                if isNaming {
                    namingField
                } else {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.spring(duration: 0.25)) { isNaming = true }
                            newName = suggestedName
                            DispatchQueue.main.async { nameFocused = true }
                        } label: {
                            Label("Save Current Layout", systemImage: "plus.circle")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)

                        Button {
                            AppDelegate.shared?.showWorkspaceTemplates()
                        } label: {
                            Label("Templates", systemImage: "square.grid.2x2.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var suggestedName: String {
        "Workspace \(service.workspaces.count + 1)"
    }

    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 8) {
            Image(systemName: workspace.symbolName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(workspace.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if workspace.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Favorite")
                    }
                    if workspace.restoreOnLaunch {
                        Image(systemName: "power")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .help("Restores automatically at launch")
                            .accessibilityLabel("Restores on launch")
                    }
                }
                Text("\(workspace.windows.count) windows")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                service.restore(workspace)
            } label: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(PressableButtonStyle())
            .help("Restore this workspace")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .hoverRowBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(workspace.name), \(workspace.windows.count) windows")
        .accessibilityHint("Double-tap to restore this workspace.")
        .accessibilityAction(named: "Restore") { service.restore(workspace) }
        .contextMenu {
            Button("Restore") { service.restore(workspace) }
            Button(workspace.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                service.toggleFavorite(workspace)
            }
            Button(workspace.restoreOnLaunch ? "Don't Restore on Launch" : "Restore on Launch") {
                service.setRestoreOnLaunch(!workspace.restoreOnLaunch, for: workspace)
            }
            Divider()
            Button("Rename…") {
                renameText = workspace.name
                renamingID = workspace.persistentModelID
                DispatchQueue.main.async { renameFocused = true }
            }
            Button("Duplicate") {
                service.duplicate(workspace, named: "\(workspace.name) Copy")
            }
            Divider()
            Button("Delete", role: .destructive) { service.delete(workspace) }
        }
    }

    private func renameField(_ workspace: Workspace) -> some View {
        HStack(spacing: 8) {
            TextField("Workspace name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($renameFocused)
                .onSubmit { commitRename(workspace) }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
            Button("Save") { commitRename(workspace) }
                .controlSize(.small)
            Button {
                renamingID = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private func commitRename(_ workspace: Workspace) {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { service.rename(workspace, to: name) }
        renamingID = nil
    }

    private var namingField: some View {
        HStack(spacing: 8) {
            TextField("Workspace name", text: $newName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($nameFocused)
                .onSubmit(saveNew)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            Button("Save", action: saveNew)
                .controlSize(.small)
            Button {
                withAnimation(.spring(duration: 0.25)) { isNaming = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private func saveNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        service.saveCurrentLayout(named: name)
        withAnimation(.spring(duration: 0.25)) { isNaming = false }
        newName = ""
    }
}

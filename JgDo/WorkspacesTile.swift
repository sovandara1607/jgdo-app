import SwiftUI
import AppKit
import SwiftData

/// Popover tile for saving and restoring window workspaces.
struct WorkspacesTile: View {
    @State private var service = WorkspaceService.shared
    @State private var newName = ""
    @State private var isNaming = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        MetricTile(icon: "square.grid.2x2", title: "Workspaces", value: "", progress: nil) {
            VStack(alignment: .leading, spacing: 8) {
                if service.workspaces.isEmpty && !isNaming {
                    Text("Save your current window arrangement and bring it back with one click.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(service.workspaces, id: \.persistentModelID) { workspace in
                    workspaceRow(workspace)
                }

                if isNaming {
                    namingField
                } else {
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
                Text(workspace.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(workspace.windows.count) windows")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button {
                service.restore(workspace)
            } label: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Restore this workspace")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Restore") { service.restore(workspace) }
            Divider()
            Button("Delete", role: .destructive) { service.delete(workspace) }
        }
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

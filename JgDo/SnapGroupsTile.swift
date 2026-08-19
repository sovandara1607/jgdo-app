import SwiftUI
import AppKit
import SwiftData

/// Popover tile for creating and managing Snap Groups — see
/// `SnapGroupService` for what "move"/"fit to screen" mean in scope here.
struct SnapGroupsTile: View {
    @State private var service = SnapGroupService.shared
    @State private var newName = ""
    @State private var isNaming = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        MetricTile(icon: "square.on.square", title: "Snap Groups", value: "", progress: nil) {
            VStack(alignment: .leading, spacing: 8) {
                if service.groups.isEmpty && !isNaming {
                    Text("Group the current windows and manage them together — move, resize, minimize, or close as one unit.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(service.groups, id: \.persistentModelID) { group in
                    groupRow(group)
                }

                if isNaming {
                    namingField
                } else {
                    Button {
                        withAnimation(.spring(duration: 0.25)) { isNaming = true }
                        newName = suggestedName
                        DispatchQueue.main.async { nameFocused = true }
                    } label: {
                        Label("Create Group from Current Windows", systemImage: "plus.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var suggestedName: String {
        "Group \(service.groups.count + 1)"
    }

    private func groupRow(_ group: SnapGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "square.on.square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(group.members.count) windows")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Button {
                service.restore(group)
            } label: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Restore this group")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Restore") { service.restore(group) }
            if let screen = NSScreen.main {
                Button("Fit to Screen") { service.fitToScreen(group, screen: screen) }
            }
            Menu("Move to Display") {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                    Button(screen.localizedName) { service.moveGroup(group, to: screen) }
                }
            }
            Divider()
            Button("Minimize") { service.minimizeGroup(group) }
            Button("Restore from Minimize") { service.restoreFromMinimize(group) }
            Button("Hide") { service.hideGroup(group) }
            Divider()
            Button("Park Group") { service.parkGroup(group) }
            Button("Restore Parked Group") { service.restoreParkedGroup(group) }
            Divider()
            Button("Close Windows", role: .destructive) { service.closeGroup(group) }
            Button("Delete Group", role: .destructive) { service.delete(group) }
        }
    }

    private var namingField: some View {
        HStack(spacing: 8) {
            TextField("Group name", text: $newName)
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
        service.createGroup(named: name)
        withAnimation(.spring(duration: 0.25)) { isNaming = false }
        newName = ""
    }
}

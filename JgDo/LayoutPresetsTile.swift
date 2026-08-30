import SwiftUI
import AppKit
import SwiftData

/// Popover tile for saving and reapplying app-agnostic window-layout shapes.
/// Same interaction pattern as `WorkspacesTile` — deliberately, so the two
/// read as siblings even though what they store is different (a shape vs.
/// specific apps at specific places).
struct LayoutPresetsTile: View {
    @State private var service = LayoutPresetService.shared
    @State private var newName = ""
    @State private var isNaming = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        MetricTile(icon: "rectangle.3.group", title: "Layout Presets", value: "", progress: nil) {
            VStack(alignment: .leading, spacing: 8) {
                if service.presets.isEmpty && !isNaming {
                    Text("Save a layout shape to reapply to any apps.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(service.presets, id: \.persistentModelID) { preset in
                    presetRow(preset)
                }

                if isNaming {
                    namingField
                } else {
                    Button {
                        withAnimation(.spring(duration: 0.25)) { isNaming = true }
                        newName = suggestedName
                        DispatchQueue.main.async { nameFocused = true }
                    } label: {
                        Label("Save Current Shape", systemImage: "plus.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var suggestedName: String {
        "Layout \(service.presets.count + 1)"
    }

    private func presetRow(_ preset: LayoutPreset) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(preset.slots.count) slots")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                service.apply(preset)
            } label: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(PressableButtonStyle())
            .help("Apply this layout to the current windows")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .hoverRowBackground()
        .contextMenu {
            Button("Apply") { service.apply(preset) }
            Divider()
            Button("Delete", role: .destructive) { service.delete(preset) }
        }
    }

    private var namingField: some View {
        HStack(spacing: 8) {
            TextField("Layout name", text: $newName)
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

import SwiftUI
import SwiftData

/// Popover tile for Smart Layout suggestions — mirrors `WorkspacesTile`'s
/// naming-field save flow so accepting a suggestion feels identical to the
/// existing "Save Current Layout" action, just pre-filled with a suggested
/// name. Renders nothing (zero height, no divider-worthy content) when
/// there are no pending suggestions.
///
/// Rows match `WorkspacesTile`/`SnapGroupsTile`'s flat shape (icon, name +
/// secondary line, trailing accent action) rather than each suggestion
/// getting its own nested card — one suggestion sitting in a box within a
/// tile within the tab's own card read as one container too many, and the
/// dismiss action moved into a context menu since it's secondary to Save.
struct SmartLayoutsTile: View {
    @State private var engine = SmartLayoutEngine.shared
    @State private var namingSuggestionID: PersistentIdentifier?
    @State private var newName = ""
    /// Briefly non-nil right after Save is tapped — swaps the naming
    /// field's Save button for a checkmark before the row actually
    /// disappears, instead of the row just vanishing the instant you commit.
    @State private var justSavedID: PersistentIdentifier?
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !engine.suggestions.isEmpty && TipsStore.tipsEnabled {
            MetricTile(icon: "wand.and.stars", title: "Smart Layouts", value: "", progress: nil) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(engine.suggestions, id: \.persistentModelID) { suggestion in
                        Group {
                            if namingSuggestionID == suggestion.persistentModelID {
                                namingField(for: suggestion)
                            } else {
                                suggestionRow(suggestion)
                            }
                        }
                        // Saved/ignored rows shrink out instead of popping —
                        // the remaining rows then slide up to fill the gap
                        // as a free side effect of the VStack reflowing.
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: SmartLayoutSuggestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.suggestedName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("Used \(suggestion.timesSeen)× recently")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                beginNaming(suggestion)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(PressableButtonStyle())
            .help("Save as Workspace")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .hoverRowBackground()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(suggestion.suggestedName), used \(suggestion.timesSeen) times recently")
        .accessibilityHint("Save as a workspace, or ignore this suggestion.")
        .accessibilityAction(named: "Save as Workspace") { beginNaming(suggestion) }
        .contextMenu {
            Button("Save as Workspace") { beginNaming(suggestion) }
            Divider()
            Button("Ignore") {
                withAnimation(reduceMotion ? Motion.reduced : Motion.normal) {
                    engine.ignore(suggestion)
                }
            }
        }
    }

    private func beginNaming(_ suggestion: SmartLayoutSuggestion) {
        newName = suggestion.suggestedName
        namingSuggestionID = suggestion.persistentModelID
        DispatchQueue.main.async { nameFocused = true }
    }

    private func namingField(for suggestion: SmartLayoutSuggestion) -> some View {
        let justSaved = justSavedID == suggestion.persistentModelID
        return HStack(spacing: 8) {
            TextField("Workspace name", text: $newName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($nameFocused)
                .disabled(justSaved)
                .onSubmit { save(suggestion) }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            if justSaved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
                    .accessibilityLabel("Saved")
            } else {
                Button("Save", action: { save(suggestion) })
                    .controlSize(.small)
                Button {
                    namingSuggestionID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Confirms visibly (+ field → ✓) before the row actually disappears,
    /// rather than the suggestion just popping out of existence the instant
    /// Save commits — no popup, just a brief, legible state change in place.
    private func save(_ suggestion: SmartLayoutSuggestion) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        withAnimation(reduceMotion ? Motion.reduced : Motion.fast) {
            justSavedID = suggestion.persistentModelID
        }
        let delay = reduceMotion ? 0.05 : 0.22
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(reduceMotion ? Motion.reduced : Motion.normal) {
                engine.acceptAsWorkspace(suggestion, named: name)
            }
            namingSuggestionID = nil
            justSavedID = nil
            newName = ""
        }
    }
}

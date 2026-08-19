import SwiftUI
import AppKit
import SwiftData

/// Popover tile listing parked windows — "Park Window" is JgDo's own
/// searchable-list alternative to plain minimize (see `WindowParkingService`).
struct ParkedWindowsTile: View {
    @State private var service = WindowParkingService.shared

    var body: some View {
        MetricTile(icon: "eye.slash", title: "Parked Windows",
                   value: service.parkedWindows.isEmpty ? "" : "\(service.parkedWindows.count)",
                   progress: nil) {
            VStack(alignment: .leading, spacing: 6) {
                if service.parkedWindows.isEmpty {
                    Text("Park a window to tuck it out of the way without losing its place — restore it exactly where it was.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(service.parkedWindows, id: \.persistentModelID) { parked in
                        parkedRow(parked)
                    }
                    if service.parkedWindows.count > 1 {
                        Button("Restore All") { service.restoreAll() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }

    private func parkedRow(_ parked: ParkedWindow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(parked.appName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(parked.title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                service.restore(parked)
            } label: {
                Image(systemName: "arrow.uturn.up.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Restore")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Restore") { service.restore(parked) }
            Divider()
            Button("Delete", role: .destructive) { service.delete(parked) }
        }
    }
}

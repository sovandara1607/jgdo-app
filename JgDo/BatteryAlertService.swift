import Foundation
import IOKit.ps
import UserNotifications

/// Always-on, event-driven battery watcher — deliberately independent of
/// `SystemMonitor`'s popover-gated sampling (`SystemStatusService.swift`'s
/// `sample()` only runs while something's actually showing a reading), since
/// a low-battery alert needs to fire even with no JgDo panel open. Uses
/// `IOPSNotificationCreateRunLoopSource`, which only calls back on real
/// power-source changes (not a polling loop) — negligible cost for the
/// app's whole lifetime.
@Observable
final class BatteryAlertService {
    static let shared = BatteryAlertService()
    private init() {}

    private var runLoopSource: CFRunLoopSource?
    /// True once we've fired for the CURRENT below-threshold streak — reset
    /// only when charging resumes or the percentage recovers above
    /// threshold, so one discharge cycle produces exactly one alert.
    private var didAlertThisCycle = false

    func start() {
        guard runLoopSource == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<BatteryAlertService>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { service.check() }
        }, context)?.takeRetainedValue() else { return }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        check()   // seed initial state in case we're launching already-low
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        runLoopSource = nil
    }

    private func check() {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let raw = IOPSGetPowerSourceDescription(snap, first)?.takeUnretainedValue() as? [String: Any]
        else { return }

        let cap = raw[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap = raw[kIOPSMaxCapacityKey] as? Int ?? 100
        let charging = raw[kIOPSIsChargingKey] as? Bool ?? false
        let pct = maxCap > 0 ? min(cap * 100 / maxCap, 100) : 0
        let threshold = AppSettings.lowBatteryThreshold

        if charging || pct > threshold {
            didAlertThisCycle = false
            return
        }
        guard pct <= threshold, !didAlertThisCycle else { return }
        didAlertThisCycle = true
        fireNotification(percent: pct)
    }

    private func fireNotification(percent: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Low Battery"
        content.body = "\(percent)% remaining. Connect your charger."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "com.jgdo.lowBattery", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    deinit { stop() }
}

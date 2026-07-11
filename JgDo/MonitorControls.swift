import AppKit
import SwiftUI
import CoreAudio
import AudioToolbox

// MARK: - Service

/// System output volume (CoreAudio, public API) and display brightness
/// (DisplayServices — loaded dynamically; controls hide if unavailable,
/// e.g. on external displays that only speak DDC).
@Observable
final class MonitorControlService {
    static let shared = MonitorControlService()

    /// 0…1, last read value; NaN until first refresh.
    private(set) var volume: Float = 0
    private(set) var isMuted = false
    private(set) var volumeAvailable = false
    /// 0…1 for the built-in / DisplayServices-controllable display.
    private(set) var brightness: Float = 0
    private(set) var brightnessAvailable = false

    // DisplayServices function pointers (private framework, resolved at runtime).
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getBrightnessFn: GetBrightnessFn?
    private let setBrightnessFn: SetBrightnessFn?

    private init() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        if let handle,
           let getSym = dlsym(handle, "DisplayServicesGetBrightness"),
           let setSym = dlsym(handle, "DisplayServicesSetBrightness") {
            getBrightnessFn = unsafeBitCast(getSym, to: GetBrightnessFn.self)
            setBrightnessFn = unsafeBitCast(setSym, to: SetBrightnessFn.self)
        } else {
            getBrightnessFn = nil
            setBrightnessFn = nil
        }
        refresh()
    }

    // MARK: Refresh

    func refresh() {
        refreshVolume()
        refreshBrightness()
    }

    private func refreshVolume() {
        guard let device = defaultOutputDevice() else { volumeAvailable = false; return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else {
            volumeAvailable = false
            return
        }
        volume = value
        volumeAvailable = true

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddr),
           AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &muteSize, &muted) == noErr {
            isMuted = muted != 0
        }
    }

    private func refreshBrightness() {
        guard let getBrightnessFn else { brightnessAvailable = false; return }
        let display = CGMainDisplayID()
        var value: Float = 0
        if getBrightnessFn(display, &value) == 0 {
            brightness = value
            brightnessAvailable = true
        } else {
            brightnessAvailable = false
        }
    }

    // MARK: Set

    func setVolume(_ value: Float) {
        guard let device = defaultOutputDevice() else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var v = Float32(min(max(value, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectSetPropertyData(device, &addr, 0, nil, size, &v) == noErr {
            volume = v
            if v > 0 && isMuted { setMuted(false) }
        }
    }

    func setMuted(_ muted: Bool) {
        guard let device = defaultOutputDevice() else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var v: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectSetPropertyData(device, &addr, 0, nil, size, &v) == noErr {
            isMuted = muted
        }
    }

    func setBrightness(_ value: Float) {
        guard let setBrightnessFn else { return }
        let v = min(max(value, 0), 1)
        if setBrightnessFn(CGMainDisplayID(), v) == 0 {
            brightness = v
        }
    }

    // MARK: Helpers

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }
}

// MARK: - Popover tile

/// "Display & Sound" tile shown in the status popover.
struct MonitorControlsTile: View {
    @State private var service = MonitorControlService.shared

    var body: some View {
        if service.volumeAvailable || service.brightnessAvailable {
            MetricTile(icon: "sun.max", title: "Display & Sound", value: "", progress: nil) {
                VStack(spacing: 12) {
                    if service.brightnessAvailable {
                        controlRow(icon: "sun.max.fill",
                                   value: Double(service.brightness)) {
                            service.setBrightness(Float($0))
                        }
                    }
                    if service.volumeAvailable {
                        HStack(spacing: 8) {
                            Button {
                                service.setMuted(!service.isMuted)
                            } label: {
                                Image(systemName: service.isMuted
                                      ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                            }
                            .buttonStyle(.plain)
                            .help(service.isMuted ? "Unmute" : "Mute")
                            Slider(value: Binding(
                                get: { Double(service.isMuted ? 0 : service.volume) },
                                set: { service.setVolume(Float($0)) }
                            ), in: 0...1)
                        }
                    }
                }
            }
            .onAppear { service.refresh() }
        }
    }

    private func controlRow(icon: String, value: Double,
                            onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: Binding(get: { value }, set: onChange), in: 0...1)
        }
    }
}

import Foundation
import AppKit
import Darwin
import IOKit
import IOKit.ps

// MARK: - Data model

struct SystemStatus {
    // CPU
    var cpuPercent: Double = 0   // user + system (+ nice) — total busy
    var cpuUser:    Double = 0   // user + nice
    var cpuSystem:  Double = 0   // kernel / system
    var cpuPerCore: [Double] = []

    // Memory (all in bytes)
    var memApp:        UInt64 = 0    // active pages
    var memWired:      UInt64 = 0    // wired (kernel/drivers)
    var memCompressed: UInt64 = 0    // compressed pages
    var memCached:     UInt64 = 0    // inactive (OS cache)
    var memFree:       UInt64 = 0
    var memTotal:      UInt64 = 0
    var swapUsed:      UInt64 = 0
    var swapTotal:     UInt64 = 0
    
    

    // Disk
    var diskUsed:       UInt64 = 0
    var diskTotal:      UInt64 = 0
    var diskReadSpeed:  Double = 0   // bytes/s
    var diskWriteSpeed: Double = 0   // bytes/s

    // Network
    var netDownSpeed: Double = 0     // bytes/s
    var netUpSpeed:   Double = 0     // bytes/s

    // Battery
    var batteryPercent:        Int  = 0
    var isCharging:            Bool = false
    var hasBattery:            Bool = false
    var batteryMinutesRemain:  Int  = -1   // -1 = unknown

    // Derived
    var memUsed:     UInt64 { memApp + memWired + memCompressed }
    var memPercent:  Double { memTotal  > 0 ? Double(memUsed)  / Double(memTotal)  : 0 }
    var diskPercent: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0 }
}

// MARK: - Observable singleton

@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()
    var status = SystemStatus()
    private var timer: Timer?
    private let fetcher = SystemStatusFetcher()
    // Serial queue: keeps the fetcher's delta state (prevCPU/prevNet/…) free of
    // races and guarantees samples never overlap, even if a disk walk runs long.
    private let sampleQueue = DispatchQueue(label: "com.jgdo.systemmonitor.sample", qos: .utility)
    private init() {}

    /// Begin sampling. Idempotent — safe to call repeatedly (e.g. each time the
    /// status popover opens). Sampling is paused via `stop()` when the popover
    /// closes so the app uses no background CPU while idle.
    func start() {
        guard timer == nil else { return }

        // Seed delta counters AND publish absolute values (mem/disk/battery) in
        // one pass. CPU/net/disk-speed read 0 here because there's no previous
        // sample yet — that's correct. We must NOT immediately fetch() a second
        // time: the delta would be measured over a sub-millisecond window
        // dominated by our own sampling code, spiking CPU toward 100%.
        sample()

        // First real delta sample so CPU/network appear within ~0.6s instead of
        // waiting a full interval.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.sample()
        }

        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        // .common mode keeps it firing during popover/menu tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Gather a sample off the main thread (the IORegistry/getifaddrs walks are
    /// the costly part), then publish on the main thread for SwiftUI.
    private func sample() {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.fetcher.fetch()
            DispatchQueue.main.async {
                guard self.timer != nil else { return }
                self.status = snapshot
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Low-level data fetcher

final class SystemStatusFetcher {

    // Delta tracking
    private var prevCPU:  (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32) = (0,0,0,0)
    private var prevCores: [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)] = []
    private var prevNet:  (down: UInt64, up: UInt64, t: Date) = (0, 0, Date())
    private var prevDisk: (read: UInt64, write: UInt64, t: Date) = (0, 0, Date())

    // The IORegistry walk in diskIOCumulative() is by far the costliest sample,
    // so we run it only every other fetch and reuse the last speeds in between.
    // The delta divides by real elapsed time, so bytes/s stays accurate.
    private var diskTick = 0
    private var lastDiskSpeeds: (readSpeed: Double, writeSpeed: Double) = (0, 0)

    @discardableResult
    func fetch() -> SystemStatus {
        var s = SystemStatus()
        (s.cpuPercent,
         s.cpuUser, s.cpuSystem)  = cpuOverall()
        s.cpuPerCore              = cpuPerCore()
        (s.memApp, s.memWired,
         s.memCompressed,
         s.memCached, s.memFree,
         s.memTotal)              = memBreakdown()
        (s.swapUsed, s.swapTotal) = swapUsage()
        (s.diskUsed, s.diskTotal) = diskStorage()
        (s.diskReadSpeed,
         s.diskWriteSpeed)        = diskIO()
        (s.netDownSpeed,
         s.netUpSpeed)            = networkSpeeds()
        (s.batteryPercent,
         s.isCharging,
         s.hasBattery,
         s.batteryMinutesRemain) = battery()
        return s
    }

    // MARK: - CPU overall (HOST_CPU_LOAD_INFO delta)

    private func cpuOverall() -> (total: Double, user: Double, system: Double) {
        var info  = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0) }

        let cur = info.cpu_ticks   // (user, sys, idle, nice)
        let dUser = cur.0 &- prevCPU.user
        let dSys  = cur.1 &- prevCPU.sys
        let dIdle = cur.2 &- prevCPU.idle
        let dNice = cur.3 &- prevCPU.nice
        let total = dUser + dSys + dIdle + dNice

        prevCPU = (cur.0, cur.1, cur.2, cur.3)
        guard total > 0 else { return (0, 0, 0) }

        // nice is user-space work at adjusted priority → group it with user,
        // matching Activity Monitor's User vs System split.
        let user = Double(dUser + dNice) / Double(total) * 100
        let sys  = Double(dSys)          / Double(total) * 100
        return (user + sys, user, sys)
    }

    // MARK: - CPU per-core (host_processor_info)

    private let CPU_STATE_COUNT: Int = 4  // USER, SYS, IDLE, NICE

    private func cpuPerCore() -> [Double] {
        var numCPUs: natural_t = 0
        var infoPtr: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0

        let kr = host_processor_info(
            mach_host_self(),
            processor_flavor_t(PROCESSOR_CPU_LOAD_INFO),
            &numCPUs, &infoPtr, &infoCount
        )
        guard kr == KERN_SUCCESS, let info = infoPtr else { return [] }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var usages = [Double]()
        var newPrev = [(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)]()

        for i in 0..<Int(numCPUs) {
            let b    = i * CPU_STATE_COUNT
            let user = UInt32(bitPattern: Int32(info[b + 0]))
            let sys  = UInt32(bitPattern: Int32(info[b + 1]))
            let idle = UInt32(bitPattern: Int32(info[b + 2]))
            let nice = UInt32(bitPattern: Int32(info[b + 3]))
            newPrev.append((user, sys, idle, nice))

            if i < prevCores.count {
                let p = prevCores[i]
                let du = user &- p.user
                let ds = sys  &- p.sys
                let di = idle &- p.idle
                let dn = nice &- p.nice
                let total = du + ds + di + dn
                usages.append(total > 0 ? Double(du + ds + dn) / Double(total) * 100 : 0)
            } else {
                usages.append(0)
            }
        }
        prevCores = newPrev
        return usages
    }

    // MARK: - Memory breakdown (vm_statistics64)

    private func memBreakdown() -> (app: UInt64, wired: UInt64, compressed: UInt64,
                                    cached: UInt64, free: UInt64, total: UInt64) {
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)
        var vm    = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0,0,0,0,0, total) }

        let pg  = UInt64(vm_page_size)
        let app  = UInt64(vm.active_count)   * pg
        let wire = UInt64(vm.wire_count)      * pg
        let comp = UInt64(vm.compressor_page_count) * pg
        let inact = UInt64(vm.inactive_count) * pg
        let free  = UInt64(vm.free_count)     * pg
        return (app, wire, comp, inact, free, total)
    }

    // MARK: - Swap (sysctl vm.swapusage)

    private func swapUsage() -> (used: UInt64, total: UInt64) {
        var xsw  = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &xsw, &size, nil, 0)
        return (xsw.xsu_used, xsw.xsu_total)
    }

    // MARK: - Disk storage

    private func diskStorage() -> (used: UInt64, total: UInt64) {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else {
            return (0, 0)
        }
        let tot  = UInt64(v.volumeTotalCapacity ?? 0)
        let avail = UInt64(v.volumeAvailableCapacityForImportantUsage ?? 0)
        return (tot > avail ? tot - avail : 0, tot)
    }

    // MARK: - Disk I/O speed (IOBlockStorageDriver cumulative delta)

    private func diskIO() -> (readSpeed: Double, writeSpeed: Double) {
        diskTick += 1
        // Skip the expensive registry walk on odd ticks (~every 4s instead of 2s)
        // and report the previously-computed speeds.
        guard diskTick % 2 == 0 else { return lastDiskSpeeds }

        let (r, w) = diskIOCumulative()
        let now = Date()
        let dt  = now.timeIntervalSince(prevDisk.t)
        var rSpd = 0.0, wSpd = 0.0
        if dt > 0 && prevDisk.read > 0 {
            rSpd = max(Double(r &- prevDisk.read) / dt, 0)
            wSpd = max(Double(w &- prevDisk.write) / dt, 0)
        }
        prevDisk = (r, w, now)
        lastDiskSpeeds = (rSpd, wSpd)
        return lastDiskSpeeds
    }

    private func diskIOCumulative() -> (read: UInt64, write: UInt64) {
        var totalRead: UInt64 = 0, totalWrite: UInt64 = 0
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &it
        ) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(it) }

        var svc: io_object_t = IOIteratorNext(it)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(it) }
            var ref: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &ref, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = ref?.takeRetainedValue() as? [String: Any],
                  let st = d["Statistics"] as? [String: Any] else { continue }
            totalRead  += st["Bytes (Read)"]  as? UInt64 ?? 0
            totalWrite += st["Bytes (Write)"] as? UInt64 ?? 0
        }
        return (totalRead, totalWrite)
    }

    // MARK: - Network speed (getifaddrs cumulative delta)

    private func networkSpeeds() -> (down: Double, up: Double) {
        let (d, u) = networkCumulative()
        let now = Date()
        let dt  = now.timeIntervalSince(prevNet.t)
        var dSpd = 0.0, uSpd = 0.0
        if dt > 0 && prevNet.down > 0 {
            dSpd = max(Double(d &- prevNet.down) / dt, 0)
            uSpd = max(Double(u &- prevNet.up)   / dt, 0)
        }
        prevNet = (d, u, now)
        return (dSpd, uSpd)
    }

    private func networkCumulative() -> (down: UInt64, up: UInt64) {
        var totalDown: UInt64 = 0, totalUp: UInt64 = 0
        var ifHead: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifHead) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifHead) }

        var ptr = ifHead
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            if let dataPtr = ifa.pointee.ifa_data {
                let ifData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                totalDown += UInt64(ifData.ifi_ibytes)
                totalUp   += UInt64(ifData.ifi_obytes)
            }
        }
        return (totalDown, totalUp)
    }

    // MARK: - Battery (IOPowerSources)

    private func battery() -> (percent: Int, charging: Bool, has: Bool, minutesRemain: Int) {
        let snap = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(snap).takeRetainedValue() as [CFTypeRef]
        guard let first = list.first,
              let raw  = IOPSGetPowerSourceDescription(snap, first),
              let dict = raw.takeUnretainedValue() as? [String: Any]
        else { return (0, false, false, -1) }

        let cap      = dict[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap   = dict[kIOPSMaxCapacityKey]     as? Int ?? 100
        let charging = dict[kIOPSIsChargingKey]      as? Bool ?? false
        let pct      = maxCap > 0 ? min(cap * 100 / maxCap, 100) : 0

        let toEmpty  = dict[kIOPSTimeToEmptyKey]        as? Int ?? -1
        let toFull   = dict[kIOPSTimeToFullChargeKey]   as? Int ?? -1
        let remain   = charging ? toFull : toEmpty

        return (pct, charging, true, remain)
    }
}

// MARK: - Formatting helpers

extension Double {
    func asSpeed() -> String {
        if      self >= 1_073_741_824 { return String(format: "%.1f GB/s", self / 1_073_741_824) }
        else if self >= 1_048_576     { return String(format: "%.1f MB/s", self / 1_048_576) }
        else if self >= 1_024         { return String(format: "%.0f KB/s", self / 1_024) }
        else                          { return String(format: "%.0f B/s",  self) }
    }
}

extension UInt64 {
    var asGB: String {
        let gb = Double(self) / 1_073_741_824
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }
    var asMB: String { String(format: "%.0f MB", Double(self) / 1_048_576) }
}

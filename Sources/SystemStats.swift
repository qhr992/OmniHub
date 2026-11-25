import Foundation
import IOKit
import Darwin

extension Notification.Name {
    static let activityChanged = Notification.Name("omnihub.activityChanged")
}

/// Activity: CPU / GPU / memory / disk usage, network throughput, the
/// battery and IP addresses.
///
/// Sampling runs while something needs it (`retain` / `release`): the
/// activity page and the menu-bar runner.
final class SystemStats {
    static let shared = SystemStats()

    struct Snapshot {
        var cpu: Double?            // 0…1, all cores
        var gpu: Double?            // 0…1, busiest GPU
        var memoryUsed: UInt64 = 0
        var memoryTotal: UInt64 = 0
        var diskUsed: Int64 = 0
        var diskTotal: Int64 = 0
        var localIPs: [(name: String, address: String)] = []
        var publicIP: String?
        var diskRead: Double = 0    // bytes per second
        var diskWrite: Double = 0
        var netIn: Double = 0       // bytes per second, Wi-Fi and Ethernet
        var netOut: Double = 0
        var battery: BatteryInfo?
    }

    /// Recent readings, oldest first — what the charts draw.
    struct History {
        var cpu: [Double] = []
        var gpu: [Double] = []
        var memory: [Double] = []
        var diskIO: [Double] = []   // read + write, bytes per second
        var network: [Double] = []  // in + out, bytes per second
        static let capacity = 60

        mutating func push(_ snapshot: Snapshot) {
            func add(_ list: inout [Double], _ value: Double) {
                list.append(value)
                if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
            }
            add(&cpu, snapshot.cpu ?? 0)
            add(&gpu, snapshot.gpu ?? 0)
            add(&memory, snapshot.memoryTotal > 0 ? Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal) : 0)
            add(&diskIO, snapshot.diskRead + snapshot.diskWrite)
            add(&network, snapshot.netIn + snapshot.netOut)
        }
    }

    private(set) var history = History()
    private var previousDisk: (read: UInt64, write: UInt64, at: Date)?
    private var previousNet: (input: UInt64, output: UInt64, at: Date)?

    private(set) var snapshot = Snapshot()
    private var timer: Timer?
    private var users = 0
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var publicIPFetchedAt = Date.distantPast
    private let queue = DispatchQueue(label: "omnihub.stats", qos: .utility)

    func retain() {
        users += 1
        guard timer == nil else { return }
        sample()
        let interval = TimeInterval(max(1, Prefs.int("activity.interval", 2)))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
        previousTicks = nil
        previousDisk = nil
        previousNet = nil
    }

    /// Picks up a changed sampling interval.
    func restartIfRunning() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        users -= 1
        retain()
    }

    /// One-shot reading (diagnostics); CPU needs two samples so it waits.
    func sampleNow(completion: @escaping (Snapshot) -> Void) {
        _ = cpuUsage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.collect { completion($0) }
        }
    }

    /// Takes one reading right now and publishes it (headless verification).
    func loadOnce(completion: @escaping () -> Void) {
        sampleNow { [weak self] next in
            self?.snapshot = next
            self?.history.push(next)
            NotificationCenter.default.post(name: .activityChanged, object: nil)
            completion()
        }
    }

    private func sample() {
        collect { [weak self] next in
            self?.snapshot = next
            self?.history.push(next)
            NotificationCenter.default.post(name: .activityChanged, object: nil)
        }
    }

    private func collect(_ completion: @escaping (Snapshot) -> Void) {
        let wantPublic = Prefs.bool("activity.publicIP", false)
        let knownPublic = snapshot.publicIP
        queue.async {
            var next = Snapshot()
            next.cpu = self.cpuUsage()
            next.gpu = Self.gpuUsage()
            (next.memoryUsed, next.memoryTotal) = Self.memory()
            (next.diskUsed, next.diskTotal) = Self.disk()
            (next.diskRead, next.diskWrite) = self.diskRates()
            (next.netIn, next.netOut) = self.networkRates()
            next.battery = BatteryInfo.read()
            next.localIPs = Self.localAddresses()
            next.publicIP = wantPublic ? knownPublic : nil
            DispatchQueue.main.async {
                completion(next)
                if wantPublic { self.refreshPublicIP() }
            }
        }
    }

    // MARK: CPU

    /// Share of non-idle ticks since the previous call.
    private func cpuUsage() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { previousTicks = (busy, total) }
        guard let previous = previousTicks, total > previous.total else { return nil }
        return Double(busy - previous.busy) / Double(total - previous.total)
    }

    // MARK: GPU

    /// "Device Utilization %" published by the graphics accelerators —
    /// the same figure Activity Monitor's GPU history is built on.
    static func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
                ?? (stats["GPU Activity(%)"] as? NSNumber)?.doubleValue
            if let value { best = max(best ?? 0, value / 100) }
        }
        return best
    }

    // MARK: Memory

    /// Used = active + wired + compressed, the way Activity Monitor counts it.
    static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return (min(pages * UInt64(pageSize), total), total)
    }

    // MARK: Disk

    static func disk() -> (used: Int64, total: Int64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                             .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return (0, 0) }
        return (Int64(total) - available, Int64(total))
    }

    /// Bytes read / written per second across all drives since the last call.
    private func diskRates() -> (Double, Double) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, write: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let raw = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                            kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = raw as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        let now = Date()
        defer { previousDisk = (read, write, now) }
        guard let previous = previousDisk, read >= previous.read, write >= previous.write else { return (0, 0) }
        let seconds = max(now.timeIntervalSince(previous.at), 0.2)
        return (Double(read - previous.read) / seconds, Double(write - previous.write) / seconds)
    }

    // MARK: Network

    /// Bytes received / sent per second on the Wi-Fi and Ethernet ports
    /// (`en*`) since the last call. VPN tunnels and the loopback are left
    /// out: their traffic also crosses a physical port.
    private func networkRates() -> (Double, Double) {
        let (input, output) = Self.networkCounters()
        let now = Date()
        defer { previousNet = (input, output, now) }
        guard let previous = previousNet, input >= previous.input, output >= previous.output else { return (0, 0) }
        let seconds = max(now.timeIntervalSince(previous.at), 0.2)
        return (Double(input - previous.input) / seconds, Double(output - previous.output) / seconds)
    }

    /// Byte counters of the `en*` interfaces, from the interface MIB (as
    /// `netstat -ib`). The routing sysctl's `RTM_IFINFO2` and `getifaddrs`
    /// hand out counters cut to 32 bits, which wrap every 4 GB.
    static func networkCounters() -> (input: UInt64, output: UInt64) {
        guard let names = if_nameindex() else { return (0, 0) }
        defer { if_freenameindex(names) }
        var input: UInt64 = 0, output: UInt64 = 0
        var cursor = names
        while cursor.pointee.if_index != 0 {
            defer { cursor = cursor.successor() }
            guard String(cString: cursor.pointee.if_name).hasPrefix("en") else { continue }
            var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA,
                                Int32(cursor.pointee.if_index), IFDATA_GENERAL]
            var data = ifmibdata()
            var length = MemoryLayout<ifmibdata>.size
            guard sysctl(&mib, 6, &data, &length, nil, 0) == 0 else { continue }
            input += data.ifmd_data.ifi_ibytes
            output += data.ifmd_data.ifi_obytes
        }
        return (input, output)
    }

    // MARK: IP

    /// IPv4 addresses of the active, non-loopback interfaces.
    static func localAddresses() -> [(name: String, address: String)] {
        var out: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            out.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
        }
        return out
    }

    /// Asks an external service, so it is opt-in and at most once a minute.
    private func refreshPublicIP() {
        guard Date().timeIntervalSince(publicIPFetchedAt) > 60,
              let url = URL(string: "https://api.ipify.org") else { return }
        publicIPFetchedAt = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let text = String(data: data, encoding: .utf8),
                  text.count < 64, !text.isEmpty else { return }
            DispatchQueue.main.async {
                self?.snapshot.publicIP = text.trimmingCharacters(in: .whitespacesAndNewlines)
                NotificationCenter.default.post(name: .activityChanged, object: nil)
            }
        }.resume()
    }

    // MARK: Formatting

    /// "1.2 MB/s"-style transfer rate.
    static func rate(_ value: Double) -> String {
        if value < 1024 { return String(format: "%.0f B/s", value) }
        if value < 1024 * 1024 { return String(format: "%.0f KB/s", value / 1024) }
        return String(format: "%.1f MB/s", value / 1024 / 1024)
    }

    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: value)
    }
}

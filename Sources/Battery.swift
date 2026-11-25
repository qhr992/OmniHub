import Foundation
import IOKit
import IOKit.ps

/// The internal battery: charge from the power-source API, the rest (health,
/// cycles, temperature, electrical readings) from the battery's registry
/// entry. Read-only; nil on a Mac without a battery.
struct BatteryInfo: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
    /// Minutes to full (charging) or to empty (on battery), when known.
    var minutesLeft: Int?
    var cycleCount: Int?
    /// Full-charge capacity now / as designed, mAh.
    var maxCapacity: Int?
    var designCapacity: Int?
    var temperature: Double?        // °C
    var voltage: Double?            // V
    var amperage: Double?           // A, negative while discharging
    var adapterWatts: Int?
    var lowPowerMode: Bool

    var isFull: Bool { pluggedIn && !charging && percent >= 95 }

    /// Every state the battery can be shown in, most pressing first.
    enum State {
        case charging       // taking charge
        case full           // on the adapter, charged
        case held           // on the adapter but not charging (optimised charging, a charge limit, a weak adapter)
        case critical       // on battery, 10 % or less
        case lowPower       // on battery, Low Power Mode
        case low            // on battery, 20 % or less
        case normal         // on battery
    }

    var state: State {
        if charging { return .charging }
        if pluggedIn { return percent >= 95 ? .full : .held }
        if percent <= 10 { return .critical }
        if lowPowerMode { return .lowPower }
        if percent <= 20 { return .low }
        return .normal
    }

    /// Full-charge capacity against design, 0…1.
    var health: Double? {
        guard let maxCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return Double(maxCapacity) / Double(designCapacity)
    }

    /// Power into (+) or out of (−) the battery, W.
    var watts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }

    var stateText: String {
        switch state {
        case .charging: return L("Charging")
        case .full: return L("Charged")
        case .held: return L("Plugged in, not charging")
        case .critical: return L("Battery very low")
        case .lowPower: return L("Low Power Mode")
        case .low: return L("Battery low")
        case .normal: return L("On battery")
        }
    }

    /// The small sign shown next to the figure, if the state has one.
    var stateSymbol: String? {
        switch state {
        case .charging: return "bolt.fill"
        case .full, .held: return "powerplug.fill"
        case .critical: return "exclamationmark"
        case .lowPower, .low, .normal: return nil
        }
    }

    /// SF Symbol for the charge and state.
    var symbol: String {
        if charging { return "battery.100percent.bolt" }
        let step = percent >= 88 ? 100 : percent >= 63 ? 75 : percent >= 38 ? 50 : percent >= 13 ? 25 : 0
        return "battery.\(step)percent"
    }

    static func read() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = max(description[kIOPSMaxCapacityKey] as? Int ?? 100, 1)
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = (charging ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
            var info = BatteryInfo(percent: min(100, max(0, current * 100 / maximum)), charging: charging,
                                   pluggedIn: pluggedIn, minutesLeft: (minutes ?? -1) > 0 ? minutes : nil,
                                   lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
            info.addRegistryReadings()
            if pluggedIn, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
                info.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
            }
            return info
        }
        return nil
    }

    private init(percent: Int, charging: Bool, pluggedIn: Bool, minutesLeft: Int?, lowPowerMode: Bool) {
        self.percent = percent
        self.charging = charging
        self.pluggedIn = pluggedIn
        self.minutesLeft = minutesLeft
        self.lowPowerMode = lowPowerMode
    }

    /// Test hook: a battery in a given state.
    static func sample(percent: Int, charging: Bool = false, pluggedIn: Bool = false,
                       lowPowerMode: Bool = false) -> BatteryInfo {
        BatteryInfo(percent: percent, charging: charging, pluggedIn: pluggedIn, minutesLeft: nil, lowPowerMode: lowPowerMode)
    }

    /// AppleSmartBattery: the same figures System Information shows.
    private mutating func addRegistryReadings() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return }
        func int(_ key: String) -> Int? { (values[key] as? NSNumber)?.intValue }
        cycleCount = int("CycleCount")
        designCapacity = int("DesignCapacity")
        // Apple silicon reports MaxCapacity as a percentage; the mAh figure
        // is AppleRawMaxCapacity there.
        maxCapacity = int("AppleRawMaxCapacity") ?? int("MaxCapacity").flatMap { $0 > 100 ? $0 : nil }
        if let raw = int("Temperature"), raw > 0 { temperature = Double(raw) / 100 }
        if let raw = int("Voltage"), raw > 0 { voltage = Double(raw) / 1000 }
        // Amperage is a signed 16-bit-style value delivered as a large number.
        if let number = values["Amperage"] as? NSNumber { amperage = Double(Int64(truncatingIfNeeded: number.int64Value)) / 1000 }
    }
}

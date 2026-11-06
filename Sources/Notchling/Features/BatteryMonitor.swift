import Foundation
import IOKit.ps

/// Battery level and charging state via IOKit power-source APIs (no permission).
@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Int?
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    @Published private(set) var minutesRemaining: Int?

    /// Fires when the charger is connected or disconnected (used for a brief notch toast).
    var onPowerSourceChange: ((Bool) -> Void)?

    private var runLoopSource: CFRunLoopSource?

    init() {
        refresh(notify: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh(notify: true) }
        }, context)?.takeRetainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    var hasBattery: Bool { level != nil }

    private func refresh(notify: Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let wasPluggedIn = isPluggedIn
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            level = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            isPluggedIn = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let tte = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
            minutesRemaining = tte > 0 ? tte : nil
        }
        if notify, wasPluggedIn != isPluggedIn { onPowerSourceChange?(isPluggedIn) }
    }
}

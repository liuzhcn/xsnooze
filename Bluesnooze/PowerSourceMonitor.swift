import Foundation
import IOKit.ps

final class PowerSourceMonitor {
    var onChange: ((PowerSourceSnapshot) -> Void)?

    private var notificationSource: CFRunLoopSource?
    private var pollTimer: Timer?

    func start() {
        if notificationSource == nil,
           let source = IOPSNotificationCreateRunLoopSource({ context in
               guard let context else {
                   return
               }

               let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
               monitor.emitCurrentSnapshot()
           }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))?.takeRetainedValue() {
            notificationSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
                self?.emitCurrentSnapshot()
            }
        }

        emitCurrentSnapshot()
    }

    func stop() {
        if let notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), notificationSource, .defaultMode)
            self.notificationSource = nil
        }

        pollTimer?.invalidate()
        pollTimer = nil
    }

    func currentSnapshot() -> PowerSourceSnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int,
                  maxCapacity > 0 else {
                continue
            }

            let powerState = description[kIOPSPowerSourceStateKey] as? String
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let chargePercentage = Int((Double(currentCapacity) / Double(maxCapacity) * 100.0).rounded())

            return PowerSourceSnapshot(
                isBatteryPower: powerState == kIOPSBatteryPowerValue,
                isCharging: isCharging,
                chargePercentage: chargePercentage
            )
        }

        return nil
    }

    private func emitCurrentSnapshot() {
        guard let snapshot = currentSnapshot() else {
            return
        }

        onChange?(snapshot)
    }
}


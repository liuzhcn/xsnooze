import AppKit

enum LowBatteryCountdownTimer {
    static func scheduledTimer(onTick: @escaping (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: 1.0, repeats: true, block: onTick)
        RunLoop.main.add(timer, forMode: .common)
        // NSAlert.runModal() uses this mode, which is not guaranteed to be common.
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .eventTracking)
        return timer
    }
}

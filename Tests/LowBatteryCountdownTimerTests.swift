import AppKit

@main
struct LowBatteryCountdownTimerTests {
    static func main() {
        countdownFires(in: .modalPanel)
        countdownFires(in: .default)
        countdownFires(in: .eventTracking)
        invalidatedCountdownDoesNotFire()
        print("LowBatteryCountdownTimerTests passed")
    }

    static func countdownFires(in mode: RunLoop.Mode) {
        var didTick = false
        let countdown = LowBatteryCountdownTimer.scheduledTimer { timer in
            didTick = true
            timer.invalidate()
        }
        defer { countdown.invalidate() }
        countdown.fireDate = .distantPast

        runLoop(in: mode)
        guard didTick else {
            print("FAIL: low-battery countdown stalled in \(mode.rawValue)")
            exit(1)
        }
    }

    static func invalidatedCountdownDoesNotFire() {
        var didTick = false
        let countdown = LowBatteryCountdownTimer.scheduledTimer { _ in
            didTick = true
        }
        countdown.fireDate = .distantPast
        countdown.invalidate()
        runLoop(in: .modalPanel)
        guard !didTick else {
            print("FAIL: canceled low-battery countdown still fired")
            exit(1)
        }
    }

    static func runLoop(in mode: RunLoop.Mode) {
        // Keep the requested mode alive even when the countdown is incorrectly
        // registered in another mode, so that the regression has a clear failure.
        let sentinel = Timer(timeInterval: 1, repeats: true) { _ in }
        RunLoop.main.add(sentinel, forMode: mode)
        defer { sentinel.invalidate() }

        let deadline = Date().addingTimeInterval(0.05)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: mode, before: deadline)
        }
    }
}

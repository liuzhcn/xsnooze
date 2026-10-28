import Foundation

enum BluetoothPowerStatus: Equatable {
    case unavailable
    case alreadyInState
    case changed
    case timedOut
}

struct BluetoothPowerResult: Equatable {
    let status: BluetoothPowerStatus
    let targetPowerOn: Bool
    let observedPowerOn: Bool?
    let elapsed: TimeInterval
}

struct BluetoothPowerController {
    var preferencesAvailable: () -> Bool
    var getPowerState: () -> CInt
    var setPowerState: (CInt) -> Void
    var wait: (TimeInterval) -> Void

    init(
        preferencesAvailable: @escaping () -> Bool,
        getPowerState: @escaping () -> CInt,
        setPowerState: @escaping (CInt) -> Void,
        wait: @escaping (TimeInterval) -> Void
    ) {
        self.preferencesAvailable = preferencesAvailable
        self.getPowerState = getPowerState
        self.setPowerState = setPowerState
        self.wait = wait
    }

    func setPower(
        _ powerOn: Bool,
        timeout: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.1,
        forceSetter: Bool = false,
        minimumWaitAfterSetter: TimeInterval = 0
    ) -> BluetoothPowerResult {
        guard preferencesAvailable() else {
            return BluetoothPowerResult(
                status: .unavailable,
                targetPowerOn: powerOn,
                observedPowerOn: nil,
                elapsed: 0
            )
        }

        let targetValue: CInt = powerOn ? 1 : 0
        var observedPowerOn = getPowerState() != 0
        if observedPowerOn == powerOn, !forceSetter {
            return BluetoothPowerResult(
                status: .alreadyInState,
                targetPowerOn: powerOn,
                observedPowerOn: observedPowerOn,
                elapsed: 0
            )
        }

        setPowerState(targetValue)

        var elapsed: TimeInterval = 0
        if minimumWaitAfterSetter > 0 {
            let waitSeconds = min(minimumWaitAfterSetter, timeout)
            wait(waitSeconds)
            elapsed += waitSeconds
        }

        while elapsed <= timeout {
            observedPowerOn = getPowerState() != 0
            if observedPowerOn == powerOn {
                return BluetoothPowerResult(
                    status: .changed,
                    targetPowerOn: powerOn,
                    observedPowerOn: observedPowerOn,
                    elapsed: elapsed
                )
            }

            guard elapsed + pollInterval <= timeout else {
                break
            }

            wait(pollInterval)
            elapsed += pollInterval
        }

        return BluetoothPowerResult(
            status: .timedOut,
            targetPowerOn: powerOn,
            observedPowerOn: observedPowerOn,
            elapsed: elapsed
        )
    }
}

/// Owns the persisted sleep state so a failed restore cannot be mistaken for user intent.
/// All calls, including scheduled actions, must run on the main thread.
final class BluetoothRestoreSession {
    private let defaults: UserDefaults
    private let stateKey: String
    private let requestPowerOn: () -> BluetoothPowerResult
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let log: (String) -> Void
    private let retryDelays: [TimeInterval] = [2, 5, 10]
    private var isAwake = false
    private var generation = 0
    private var attempts = 0

    init(
        defaults: UserDefaults,
        stateKey: String,
        requestPowerOn: @escaping () -> BluetoothPowerResult,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.stateKey = stateKey
        self.requestPowerOn = requestPowerOn
        self.schedule = schedule
        self.log = log
    }

    private var needsRestore: Bool { defaults.bool(forKey: stateKey) }

    func willSleep(cachedPowerOn: Bool?) {
        isAwake = false
        generation += 1
        attempts = 0
        guard !needsRestore else {
            log("Preserving pending Bluetooth restore across sleep.")
            return
        }
        if let cachedPowerOn {
            defaults.set(cachedPowerOn, forKey: stateKey)
        } else {
            defaults.removeObject(forKey: stateKey)
        }
    }

    /// Also used at app launch to recover a persisted, unfinished restore.
    func didWake() {
        guard !isAwake else { return }
        isAwake = true
        generation += 1
        attempts = 0
        guard needsRestore else {
            defaults.removeObject(forKey: stateKey)
            return
        }
        attemptRestore()
    }

    private func attemptRestore() {
        guard isAwake, needsRestore else { return }
        attempts += 1
        let result = requestPowerOn()
        switch result.status {
        case .changed, .alreadyInState:
            defaults.removeObject(forKey: stateKey)
            generation += 1
            log("Bluetooth restore confirmed; cleared pending state.")
        case .unavailable, .timedOut:
            guard attempts <= retryDelays.count else {
                log("Bluetooth restore retry limit reached; retaining pending state for next wake or launch.")
                return
            }
            let delay = retryDelays[attempts - 1]
            let scheduledGeneration = generation
            log("Bluetooth restore failed; scheduling retry in \(delay) seconds.")
            schedule(delay) { [weak self] in
                guard let self, self.generation == scheduledGeneration else { return }
                self.attemptRestore()
            }
        }
    }
}

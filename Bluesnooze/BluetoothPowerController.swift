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

import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fatalError("\(message): expected \(expected), got \(actual)")
    }
}

func assertTrue(_ value: Bool, _ message: String) {
    if !value {
        fatalError(message)
    }
}

func assertFalse(_ value: Bool, _ message: String) {
    if value {
        fatalError(message)
    }
}

@main
struct BluetoothPowerControllerTests {
    static func main() {
        alreadyTargetStateDoesNotCallSetter()
        forcedRequestCallsSetterAndWaitsEvenWhenGetterAlreadyMatches()
        delayedGetterChangeEventuallySucceeds()
        timeoutReportsLastObservedState()
        unavailablePreferencesFailWithoutSetter()
    }

    static func alreadyTargetStateDoesNotCallSetter() {
        var setValues: [CInt] = []
        let controller = BluetoothPowerController(
            preferencesAvailable: { true },
            getPowerState: { 1 },
            setPowerState: { setValues.append($0) },
            wait: { _ in }
        )

        let result = controller.setPower(true, timeout: 3, pollInterval: 0.1)

        assertEqual(result.status, .alreadyInState, "Already-on Bluetooth should not be changed")
        assertEqual(result.observedPowerOn, true, "Already-on result should report observed power")
        assertEqual(setValues, [], "Already target state should not call setter")
    }

    static func forcedRequestCallsSetterAndWaitsEvenWhenGetterAlreadyMatches() {
        var setValues: [CInt] = []
        var waits: [TimeInterval] = []
        let controller = BluetoothPowerController(
            preferencesAvailable: { true },
            getPowerState: { 0 },
            setPowerState: { setValues.append($0) },
            wait: { waits.append($0) }
        )

        let result = controller.setPower(
            false,
            timeout: 3,
            pollInterval: 0.1,
            forceSetter: true,
            minimumWaitAfterSetter: 1
        )

        assertEqual(result.status, .changed, "Forced off request should complete when getter reports target")
        assertEqual(result.observedPowerOn, false, "Forced off result should report observed target state")
        assertEqual(setValues, [0], "Forced request should call setter even when getter already matches")
        assertEqual(waits, [1], "Forced request should keep the caller alive after setter")
    }

    static func delayedGetterChangeEventuallySucceeds() {
        var setValues: [CInt] = []
        var observations = [1, 1, 1, 0]
        var waitCount = 0
        let controller = BluetoothPowerController(
            preferencesAvailable: { true },
            getPowerState: {
                if observations.count > 1 {
                    return CInt(observations.removeFirst())
                }
                return CInt(observations[0])
            },
            setPowerState: { setValues.append($0) },
            wait: { _ in waitCount += 1 }
        )

        let result = controller.setPower(false, timeout: 3, pollInterval: 0.1)

        assertEqual(result.status, .changed, "Bluetooth should report success after getter observes the target")
        assertEqual(result.observedPowerOn, false, "Changed result should report the target state")
        assertEqual(setValues, [0], "Bluetooth should call setter once with the target value")
        assertTrue(waitCount > 0, "Delayed change should wait before success")
    }

    static func timeoutReportsLastObservedState() {
        var setValues: [CInt] = []
        let controller = BluetoothPowerController(
            preferencesAvailable: { true },
            getPowerState: { 1 },
            setPowerState: { setValues.append($0) },
            wait: { _ in }
        )

        let result = controller.setPower(false, timeout: 0.3, pollInterval: 0.1)

        assertEqual(result.status, .timedOut, "Bluetooth should time out if getter never reaches the target")
        assertEqual(result.observedPowerOn, true, "Timeout should report the last observed state")
        assertEqual(setValues, [0], "Timed-out change should still call setter once")
    }

    static func unavailablePreferencesFailWithoutSetter() {
        var setterCalled = false
        let controller = BluetoothPowerController(
            preferencesAvailable: { false },
            getPowerState: { 1 },
            setPowerState: { _ in setterCalled = true },
            wait: { _ in }
        )

        let result = controller.setPower(false, timeout: 3, pollInterval: 0.1)

        assertEqual(result.status, .unavailable, "Unavailable Bluetooth preferences should fail")
        assertEqual(result.observedPowerOn, nil, "Unavailable result should not report an observed state")
        assertFalse(setterCalled, "Unavailable preferences should not call setter")
    }
}

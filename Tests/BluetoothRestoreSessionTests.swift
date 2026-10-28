import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        print("FAIL: \(message)")
        exit(1)
    }
}

final class RestoreFixture {
    let suite = "XSnooze.BluetoothRestoreTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let key = "bluetoothWasOnBeforeSleep"
    var hardwarePower: CInt = 0
    var acceptsRequest = false
    var preferencesAvailable = true
    var requests = 0
    var scheduled: [(TimeInterval, () -> Void)] = []
    lazy var controller = BluetoothPowerController(
        preferencesAvailable: { [unowned self] in self.preferencesAvailable },
        getPowerState: { [unowned self] in self.hardwarePower },
        setPowerState: { [unowned self] value in
            self.requests += 1
            if self.acceptsRequest { self.hardwarePower = value }
        },
        wait: { _ in }
    )
    lazy var session = makeSession()

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
    }

    func makeSession() -> BluetoothRestoreSession {
        BluetoothRestoreSession(
            defaults: defaults,
            stateKey: key,
            requestPowerOn: { [unowned self] in
                self.controller.setPower(true, timeout: 0.3, pollInterval: 0.1)
            },
            schedule: { [unowned self] delay, action in
                self.scheduled.append((delay, action))
            }
        )
    }

    func runNext() {
        expect(!scheduled.isEmpty, "A retry should be scheduled")
        scheduled.removeFirst().1()
    }
}

@main
struct BluetoothRestoreSessionTests {
    static func main() {
        failedRestoreSurvivesAnotherSleepAndWake()
        retryRecoversWithoutAnotherWake()
        retryLimitRetainsPendingState()
        sleepInvalidatesOldRetries()
        offAndUnknownStatesNeverEnableBluetooth()
        unavailablePreferencesCanRecover()
        relaunchRecoversPersistedState()
        duplicateWakeDoesNotResetRetryBudget()
        alreadyOnCompletesWithoutSetter()
        unknownSleepStatePreservesPendingRestore()
        print("PASS: 10 Bluetooth restore scenarios")
    }

    static func failedRestoreSurvivesAnotherSleepAndWake() {
        let f = RestoreFixture()
        f.session.willSleep(cachedPowerOn: true)
        f.session.didWake()
        expect(f.requests == 1, "Wake should request Bluetooth on")
        expect(f.defaults.bool(forKey: f.key), "Timed-out restore must retain the original on state")
        f.session.willSleep(cachedPowerOn: false)
        expect(f.defaults.bool(forKey: f.key), "Next sleep must not overwrite the pending restore with off")
        f.acceptsRequest = true
        f.session.didWake()
        expect(f.hardwarePower == 1, "Next wake should recover Bluetooth after the earlier timeout")
        expect(f.defaults.object(forKey: f.key) == nil, "Successful restore should clear pending state")
    }

    static func retryRecoversWithoutAnotherWake() {
        let f = RestoreFixture()
        f.session.willSleep(cachedPowerOn: true)
        f.session.didWake()
        expect(f.scheduled.first?.0 == 2, "First retry should wait two seconds")
        f.acceptsRequest = true
        f.runNext()
        expect(f.requests == 2 && f.hardwarePower == 1, "Delayed retry should restore Bluetooth")
        expect(f.defaults.object(forKey: f.key) == nil, "Retry success should clear pending state")
        expect(f.scheduled.isEmpty, "Success must stop retrying")
        // A later user-off state must remain off after sleep and wake.
        f.hardwarePower = 0
        f.session.willSleep(cachedPowerOn: false)
        f.session.didWake()
        expect(f.requests == 2, "Completed restore must not override a later off state")
    }

    static func retryLimitRetainsPendingState() {
        let f = RestoreFixture()
        f.session.willSleep(cachedPowerOn: true)
        f.session.didWake()
        for delay: TimeInterval in [2, 5, 10] {
            expect(f.scheduled.first?.0 == delay, "Retry delay should increase")
            f.runNext()
        }
        expect(f.requests == 4, "Only initial request plus three retries are allowed")
        expect(f.scheduled.isEmpty, "Exhaustion must stop the timer chain")
        expect(f.defaults.bool(forKey: f.key), "Exhaustion must retain pending state")
        f.session.willSleep(cachedPowerOn: false)
        f.acceptsRequest = true
        f.session.didWake()
        expect(f.hardwarePower == 1, "Next wake gets a new restore opportunity")
    }

    static func sleepInvalidatesOldRetries() {
        let f = RestoreFixture()
        f.session.willSleep(cachedPowerOn: true)
        f.session.didWake()
        f.session.willSleep(cachedPowerOn: false)
        f.runNext()
        expect(f.requests == 1, "Retry must not power Bluetooth on during sleep")
        f.session.didWake()
        expect(f.requests == 2, "Next wake should start a new attempt")
        f.session.willSleep(cachedPowerOn: false)
        f.session.didWake()
        expect(f.requests == 3, "Third cycle should start one attempt")
        f.runNext()
        expect(f.requests == 3, "An old retry must remain invalid after another wake")
        f.acceptsRequest = true
        f.runNext()
        expect(f.requests == 4 && f.hardwarePower == 1, "Current cycle's retry should work")
    }

    static func offAndUnknownStatesNeverEnableBluetooth() {
        for state: Bool? in [false, nil] {
            let f = RestoreFixture()
            f.session.willSleep(cachedPowerOn: state)
            f.session.didWake()
            expect(f.requests == 0, "Off or unknown state must not enable Bluetooth")
            expect(f.scheduled.isEmpty, "Off or unknown state must not schedule retries")
            expect(f.defaults.object(forKey: f.key) == nil, "No restore means no pending state")
        }
    }

    static func unavailablePreferencesCanRecover() {
        let f = RestoreFixture()
        f.preferencesAvailable = false
        f.session.willSleep(cachedPowerOn: true)
        f.session.didWake()
        expect(f.requests == 0, "Unavailable preferences must not call setter")
        expect(f.defaults.bool(forKey: f.key), "Unavailable preferences must retain restore intent")
        f.preferencesAvailable = true
        f.acceptsRequest = true
        f.runNext()
        expect(f.hardwarePower == 1, "Retry should recover when preferences become available")
    }

    static func relaunchRecoversPersistedState() {
        let f = RestoreFixture()
        var previous: BluetoothRestoreSession? = f.makeSession()
        previous?.willSleep(cachedPowerOn: true)
        previous?.didWake()
        previous = nil
        let relaunched = f.makeSession()
        f.acceptsRequest = true
        relaunched.didWake()
        expect(f.hardwarePower == 1, "Launch should recover persisted pending state")
        expect(f.defaults.object(forKey: f.key) == nil, "Launch success should clear pending state")
        f.runNext()
        expect(f.requests == 2, "A destroyed session must not run its retry")
    }

    static func duplicateWakeDoesNotResetRetryBudget() {
        let f = RestoreFixture()
        f.session.willSleep(cachedPowerOn: true)
        f.session.didWake()
        f.session.didWake()
        expect(f.requests == 1 && f.scheduled.count == 1, "Duplicate wake must not create a second retry chain")
        for _ in 0..<3 { f.runNext() }
        f.session.didWake()
        expect(f.requests == 4 && f.scheduled.isEmpty, "Duplicate wake must not bypass retry limit")
    }

    static func alreadyOnCompletesWithoutSetter() {
        let f = RestoreFixture()
        f.hardwarePower = 1
        f.session.willSleep(cachedPowerOn: true)
        f.session.didWake()
        expect(f.requests == 0, "Already-on Bluetooth needs no setter")
        expect(f.defaults.object(forKey: f.key) == nil, "Confirmed already-on state completes restore")
        expect(f.scheduled.isEmpty, "Already-on state needs no retry")
    }

    static func unknownSleepStatePreservesPendingRestore() {
        let f = RestoreFixture()
        f.session.willSleep(cachedPowerOn: true)
        f.session.didWake()
        f.session.willSleep(cachedPowerOn: nil)
        expect(f.defaults.bool(forKey: f.key), "Unknown state during reset must not erase restore intent")
        f.acceptsRequest = true
        f.session.didWake()
        expect(f.hardwarePower == 1, "Pending restore survives unknown state")
    }

}

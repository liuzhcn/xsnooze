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
struct LowBatteryPolicyTests {
    static func main() {
        assertEqual(LowBatteryPolicy.bucket(for: 30), nil, "30 percent should not map to a warning bucket")
        assertEqual(LowBatteryPolicy.bucket(for: 29), 29, "29 percent should map to the first warning bucket")
        assertEqual(LowBatteryPolicy.bucket(for: 26), 29, "26 percent should stay in the 29 bucket")
        assertEqual(LowBatteryPolicy.bucket(for: 25), 25, "25 percent should map to the second warning bucket")
        assertEqual(LowBatteryPolicy.bucket(for: 4), 5, "Critical battery should map to the 5 bucket")

        let unpluggedLowBattery = PowerSourceSnapshot(isBatteryPower: true, isCharging: false, chargePercentage: 29)
        assertTrue(LowBatteryPolicy.shouldStartWarning(for: unpluggedLowBattery, suppressedBucket: nil), "29 percent on battery should trigger")
        assertFalse(LowBatteryPolicy.shouldStartWarning(for: unpluggedLowBattery, suppressedBucket: 29), "Confirmed bucket should not repeat")

        let nextBucket = PowerSourceSnapshot(isBatteryPower: true, isCharging: false, chargePercentage: 25)
        assertTrue(LowBatteryPolicy.shouldStartWarning(for: nextBucket, suppressedBucket: 29), "Dropping into a new bucket should trigger again")

        let pluggedIn = PowerSourceSnapshot(isBatteryPower: false, isCharging: true, chargePercentage: 20)
        assertFalse(LowBatteryPolicy.shouldStartWarning(for: pluggedIn, suppressedBucket: nil), "Plugged-in Macs should not trigger")

        let charging = PowerSourceSnapshot(isBatteryPower: true, isCharging: true, chargePercentage: 20)
        assertFalse(LowBatteryPolicy.shouldStartWarning(for: charging, suppressedBucket: nil), "Charging Macs should not trigger")
    }
}

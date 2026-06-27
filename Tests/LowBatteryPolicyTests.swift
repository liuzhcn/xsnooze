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
        let defaultSettings = LowBatterySettings()
        assertTrue(defaultSettings.isEnabled, "Low-battery reminders should be enabled by default")
        assertEqual(defaultSettings.thresholdPercentage, 30, "Default threshold should preserve 1.5.1 behavior")
        assertTrue(defaultSettings.forceHibernateOnTimeout, "Forced hibernation should be enabled by default")
        assertEqual(defaultSettings.countdownSeconds, 60, "Default countdown should preserve 1.5.1 behavior")

        assertEqual(LowBatteryPolicy.bucket(for: 30, settings: defaultSettings), nil, "30 percent should not map to a warning bucket")
        assertEqual(LowBatteryPolicy.bucket(for: 29, settings: defaultSettings), 29, "29 percent should map to the first warning bucket")
        assertEqual(LowBatteryPolicy.bucket(for: 26, settings: defaultSettings), 29, "26 percent should stay in the 29 bucket")
        assertEqual(LowBatteryPolicy.bucket(for: 25, settings: defaultSettings), 25, "25 percent should map to the second warning bucket")
        assertEqual(LowBatteryPolicy.bucket(for: 4, settings: defaultSettings), 5, "Critical battery should map to the 5 bucket")

        let highThresholdSettings = LowBatterySettings(thresholdPercentage: 40)
        assertEqual(LowBatteryPolicy.bucket(for: 40, settings: highThresholdSettings), nil, "Configured threshold should be exclusive")
        assertEqual(LowBatteryPolicy.bucket(for: 39, settings: highThresholdSettings), 39, "39 percent should trigger when threshold is 40")

        let lowThresholdSettings = LowBatterySettings(thresholdPercentage: 10)
        assertEqual(LowBatteryPolicy.bucket(for: 10, settings: lowThresholdSettings), nil, "10 percent should not trigger when threshold is 10")
        assertEqual(LowBatteryPolicy.bucket(for: 9, settings: lowThresholdSettings), 9, "9 percent should trigger when threshold is 10")

        let normalizedSettings = LowBatterySettings(thresholdPercentage: 33, countdownSeconds: 62)
        assertEqual(normalizedSettings.thresholdPercentage, 35, "Threshold should snap to the nearest 5 percent")
        assertEqual(normalizedSettings.countdownSeconds, 60, "Countdown should snap to the nearest 5 seconds")

        let clampedNormalizedSettings = LowBatterySettings(thresholdPercentage: 43, countdownSeconds: 13)
        assertEqual(clampedNormalizedSettings.thresholdPercentage, 40, "Threshold should clamp after snapping")
        assertEqual(clampedNormalizedSettings.countdownSeconds, 15, "Countdown should clamp after snapping")

        assertEqual(
            LowBatterySettings.steppedValue(from: 30, delta: -LowBatterySettings.adjustmentStep, in: LowBatterySettings.thresholdRange),
            25,
            "Threshold decrement should move by one adjustment step"
        )
        assertEqual(
            LowBatterySettings.steppedValue(from: 40, delta: LowBatterySettings.adjustmentStep, in: LowBatterySettings.thresholdRange),
            40,
            "Threshold increment should not exceed the maximum"
        )
        assertEqual(
            LowBatterySettings.steppedValue(from: 15, delta: -LowBatterySettings.adjustmentStep, in: LowBatterySettings.countdownRange),
            15,
            "Countdown decrement should not go below the minimum"
        )
        assertEqual(
            LowBatterySettings.steppedValue(from: 295, delta: LowBatterySettings.adjustmentStep, in: LowBatterySettings.countdownRange),
            300,
            "Countdown increment should reach the maximum"
        )

        let unpluggedLowBattery = PowerSourceSnapshot(isBatteryPower: true, isCharging: false, chargePercentage: 29)
        assertTrue(LowBatteryPolicy.shouldStartWarning(for: unpluggedLowBattery, settings: defaultSettings, suppressedBucket: nil), "29 percent on battery should trigger")
        assertFalse(LowBatteryPolicy.shouldStartWarning(for: unpluggedLowBattery, settings: defaultSettings, suppressedBucket: 29), "Confirmed bucket should not repeat")

        let nextBucket = PowerSourceSnapshot(isBatteryPower: true, isCharging: false, chargePercentage: 25)
        assertTrue(LowBatteryPolicy.shouldStartWarning(for: nextBucket, settings: defaultSettings, suppressedBucket: 29), "Dropping into a new bucket should trigger again")

        let pluggedIn = PowerSourceSnapshot(isBatteryPower: false, isCharging: true, chargePercentage: 20)
        assertFalse(LowBatteryPolicy.shouldStartWarning(for: pluggedIn, settings: defaultSettings, suppressedBucket: nil), "Plugged-in Macs should not trigger")

        let charging = PowerSourceSnapshot(isBatteryPower: true, isCharging: true, chargePercentage: 20)
        assertFalse(LowBatteryPolicy.shouldStartWarning(for: charging, settings: defaultSettings, suppressedBucket: nil), "Charging Macs should not trigger")

        let disabledSettings = LowBatterySettings(isEnabled: false)
        assertFalse(LowBatteryPolicy.shouldStartWarning(for: unpluggedLowBattery, settings: disabledSettings, suppressedBucket: nil), "Disabled reminders should not trigger")
        assertFalse(disabledSettings.canEditCountdown, "Countdown should be disabled when reminders are disabled")

        let noHibernateSettings = LowBatterySettings(forceHibernateOnTimeout: false, countdownSeconds: 300)
        assertTrue(LowBatteryPolicy.shouldStartWarning(for: unpluggedLowBattery, settings: noHibernateSettings, suppressedBucket: nil), "Timeout settings should not affect reminder triggering")
        assertFalse(noHibernateSettings.canEditCountdown, "Countdown should be disabled when forced hibernation is disabled")
        assertTrue(defaultSettings.canEditCountdown, "Countdown should be editable when reminders and forced hibernation are enabled")
    }
}

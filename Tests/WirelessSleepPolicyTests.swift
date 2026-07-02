import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fatalError("\(message): expected \(expected), got \(actual)")
    }
}

func assertFalse(_ value: Bool, _ message: String) {
    if value {
        fatalError(message)
    }
}

@main
struct WirelessSleepPolicyTests {
    static func main() {
        cachedOnStatesAreTurnedOffAndRemembered()
        cachedOffStatesAreSkippedAndRememberedAsOff()
        unknownStatesAreSkippedAndNotRemembered()
        privateBluetoothPreferenceIsNeverTrustedForInitialCache()
    }

    static func cachedOnStatesAreTurnedOffAndRemembered() {
        let decision = WirelessSleepPolicy.sleepActions(
            cachedBluetoothWasOn: true,
            cachedWiFiWasOn: true
        )

        assertEqual(decision.bluetoothWasOn, true, "Sleep should remember cached-on Bluetooth")
        assertEqual(decision.wifiWasOn, true, "Sleep should remember cached-on Wi-Fi")
        assertEqual(decision.shouldTurnBluetoothOff, true, "Cached-on Bluetooth should be turned off")
        assertEqual(decision.shouldTurnWiFiOff, true, "Cached-on Wi-Fi should be turned off")
        assertEqual(decision.shouldStoreBluetoothState, true, "Known Bluetooth state should be stored")
        assertEqual(decision.shouldStoreWiFiState, true, "Known Wi-Fi state should be stored")
    }

    static func cachedOffStatesAreSkippedAndRememberedAsOff() {
        let decision = WirelessSleepPolicy.sleepActions(
            cachedBluetoothWasOn: false,
            cachedWiFiWasOn: false
        )

        assertEqual(decision.bluetoothWasOn, false, "Sleep should remember cached-off Bluetooth")
        assertEqual(decision.wifiWasOn, false, "Sleep should remember cached-off Wi-Fi")
        assertFalse(decision.shouldTurnBluetoothOff, "Cached-off Bluetooth should not be turned off")
        assertFalse(decision.shouldTurnWiFiOff, "Cached-off Wi-Fi should not be turned off")
        assertEqual(decision.shouldStoreBluetoothState, true, "Known Bluetooth off state should be stored")
        assertEqual(decision.shouldStoreWiFiState, true, "Known Wi-Fi off state should be stored")
    }

    static func unknownStatesAreSkippedAndNotRemembered() {
        let decision = WirelessSleepPolicy.sleepActions(
            cachedBluetoothWasOn: nil,
            cachedWiFiWasOn: nil
        )

        assertEqual(decision.bluetoothWasOn, nil, "Unknown Bluetooth state should remain unknown")
        assertEqual(decision.wifiWasOn, nil, "Unknown Wi-Fi state should remain unknown")
        assertFalse(decision.shouldTurnBluetoothOff, "Unknown Bluetooth state should not be turned off")
        assertFalse(decision.shouldTurnWiFiOff, "Unknown Wi-Fi state should not be turned off")
        assertFalse(decision.shouldStoreBluetoothState, "Unknown Bluetooth state should not be stored for wake")
        assertFalse(decision.shouldStoreWiFiState, "Unknown Wi-Fi state should not be stored for wake")
    }

    static func privateBluetoothPreferenceIsNeverTrustedForInitialCache() {
        assertEqual(
            WirelessSleepPolicy.initialBluetoothCacheState(preferencePowerOn: true),
            nil,
            "Private Bluetooth preference on should not seed the initial cache"
        )
        assertEqual(
            WirelessSleepPolicy.initialBluetoothCacheState(preferencePowerOn: false),
            nil,
            "Private Bluetooth preference off should not seed the initial cache"
        )
        assertEqual(
            WirelessSleepPolicy.initialBluetoothCacheState(preferencePowerOn: nil),
            nil,
            "Missing private Bluetooth preference should leave the initial cache unknown"
        )
    }
}

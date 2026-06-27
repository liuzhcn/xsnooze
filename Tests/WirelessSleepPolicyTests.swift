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
        var bluetoothProbeCount = 0
        var wifiProbeCount = 0

        let decision = WirelessSleepPolicy.sleepActions(
            cachedBluetoothWasOn: true,
            cachedWiFiWasOn: false,
            readCurrentBluetoothState: {
                bluetoothProbeCount += 1
                return false
            },
            readCurrentWiFiState: {
                wifiProbeCount += 1
                return true
            }
        )

        assertEqual(decision.bluetoothWasOn, true, "Sleep should use cached Bluetooth state")
        assertEqual(decision.wifiWasOn, false, "Sleep should use cached Wi-Fi state")
        assertEqual(decision.shouldTurnBluetoothOff, true, "Cached-on Bluetooth should be turned off")
        assertFalse(decision.shouldTurnWiFiOff, "Cached-off Wi-Fi should not be turned off")
        assertEqual(bluetoothProbeCount, 0, "Sleep policy must not probe Bluetooth during sleep notification")
        assertEqual(wifiProbeCount, 0, "Sleep policy must not probe Wi-Fi during sleep notification")
    }
}

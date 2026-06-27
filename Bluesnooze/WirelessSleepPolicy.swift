import Foundation

struct WirelessSleepDecision: Equatable {
    let bluetoothWasOn: Bool
    let wifiWasOn: Bool
    let shouldTurnBluetoothOff: Bool
    let shouldTurnWiFiOff: Bool
}

enum WirelessSleepPolicy {
    static func sleepActions(
        cachedBluetoothWasOn: Bool,
        cachedWiFiWasOn: Bool,
        readCurrentBluetoothState: () -> Bool,
        readCurrentWiFiState: () -> Bool
    ) -> WirelessSleepDecision {
        WirelessSleepDecision(
            bluetoothWasOn: cachedBluetoothWasOn,
            wifiWasOn: cachedWiFiWasOn,
            shouldTurnBluetoothOff: cachedBluetoothWasOn,
            shouldTurnWiFiOff: cachedWiFiWasOn
        )
    }
}

import Foundation

struct WirelessSleepDecision: Equatable {
    let bluetoothWasOn: Bool?
    let wifiWasOn: Bool?
    let shouldTurnBluetoothOff: Bool
    let shouldTurnWiFiOff: Bool
    let shouldStoreBluetoothState: Bool
    let shouldStoreWiFiState: Bool
}

enum WirelessSleepPolicy {
    static func initialBluetoothCacheState(preferencePowerOn: Bool?) -> Bool? {
        nil
    }

    static func sleepActions(
        cachedBluetoothWasOn: Bool?,
        cachedWiFiWasOn: Bool?
    ) -> WirelessSleepDecision {
        WirelessSleepDecision(
            bluetoothWasOn: cachedBluetoothWasOn,
            wifiWasOn: cachedWiFiWasOn,
            shouldTurnBluetoothOff: cachedBluetoothWasOn == true,
            shouldTurnWiFiOff: cachedWiFiWasOn == true,
            shouldStoreBluetoothState: cachedBluetoothWasOn != nil,
            shouldStoreWiFiState: cachedWiFiWasOn != nil
        )
    }
}

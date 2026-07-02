import CoreBluetooth
import CoreWLAN
import Foundation

final class WirelessStateMonitor: NSObject, CBCentralManagerDelegate, CWEventDelegate {
    var onBluetoothPowerStateChange: ((Bool?, String) -> Void)?
    var onWiFiPowerStateChange: ((Bool?, String) -> Void)?
    var onWiFiMonitoringError: ((String) -> Void)?

    private let wifiClient: CWWiFiClient
    private var bluetoothManager: CBCentralManager?

    init(wifiClient: CWWiFiClient = CWWiFiClient.shared()) {
        self.wifiClient = wifiClient
        super.init()
    }

    func start() {
        startBluetoothMonitoring()
        refreshInitialWiFiState()
        startWiFiPowerMonitoring()
    }

    private func startBluetoothMonitoring() {
        bluetoothManager = CBCentralManager(delegate: self, queue: nil)
    }

    private func refreshInitialWiFiState() {
        guard let interface = wifiClient.interface() else {
            onWiFiPowerStateChange?(nil, "initial-no-interface")
            return
        }

        onWiFiPowerStateChange?(interface.powerOn(), "initial")
    }

    private func startWiFiPowerMonitoring() {
        wifiClient.delegate = self

        do {
            try wifiClient.startMonitoringEvent(with: .powerDidChange)
        } catch {
            onWiFiMonitoringError?(error.localizedDescription)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onBluetoothPowerStateChange?(true, "CoreBluetooth")
        case .poweredOff:
            onBluetoothPowerStateChange?(false, "CoreBluetooth")
        case .unknown:
            onBluetoothPowerStateChange?(nil, "CoreBluetooth-unknown")
        case .resetting:
            onBluetoothPowerStateChange?(nil, "CoreBluetooth-resetting")
        case .unsupported:
            onBluetoothPowerStateChange?(nil, "CoreBluetooth-unsupported")
        case .unauthorized:
            onBluetoothPowerStateChange?(nil, "CoreBluetooth-unauthorized")
        @unknown default:
            onBluetoothPowerStateChange?(nil, "CoreBluetooth-unrecognized")
        }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        guard let interface = wifiClient.interface(withName: interfaceName) ?? wifiClient.interface() else {
            onWiFiPowerStateChange?(nil, "CoreWLAN-\(interfaceName)-no-interface")
            return
        }

        onWiFiPowerStateChange?(interface.powerOn(), "CoreWLAN-\(interfaceName)")
    }
}

//
//  AppDelegate.swift
//  Bluesnooze
//
//  Created by Oliver Peate on 07/04/2020.
//  Copyright © 2020 Oliver Peate. All rights reserved.
//

import Cocoa
import CoreWLAN
import IOBluetooth
import LaunchAtLogin
import OSLog

private enum AppLog {
    static let power = Logger(subsystem: "com.liuzhcn.XSnooze", category: "power")
    static let bluetooth = Logger(subsystem: "com.liuzhcn.XSnooze", category: "bluetooth")
    static let wifi = Logger(subsystem: "com.liuzhcn.XSnooze", category: "wifi")
    static let hibernate = Logger(subsystem: "com.liuzhcn.XSnooze", category: "hibernate")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var launchAtLoginMenuItem: NSMenuItem!
    @IBOutlet weak var toggleIconMenuItem: NSMenuItem!

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hideIconTask: DispatchWorkItem?
    private let bluetoothWasOnBeforeSleepKey = "bluetoothWasOnBeforeSleep"
    private let wifiWasOnBeforeSleepKey = "wifiWasOnBeforeSleep"
    private let powerSourceMonitor = PowerSourceMonitor()
    private let privilegedHelperClient = PrivilegedHelperClient()
    private var lowBatteryAlert: NSAlert?
    private var lowBatteryCountdownTimer: Timer?
    private var lowBatteryWarningDeadline: Date?
    private var lowBatteryTimedOut = false
    private var lowBatteryCanceled = false
    private var suppressedBatteryBucket: Int?
    private let lowBatteryCountdownSeconds = 60

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        initStatusItem()
        setLaunchAtLoginState()
        setToggleIconState()
        setupNotificationHandlers()
        privilegedHelperClient.restoreHibernationModeIfNeeded()
        setupLowBatteryMonitor()
    }
    
    // 处理应用程序被再次打开的情况
    func applicationWillBecomeActive(_ notification: Notification) {
        showTemporaryIcon()
    }
    
    // 处理应用程序被用户通过 Dock 或 Finder 打开的情况
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showTemporaryIcon()
        return true
    }
    
    // 处理应用程序被再次激活的情况（如通过点击 Dock 图标）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTemporaryIcon()
        return true
    }
    
    // 显示临时图标的通用方法
    private func showTemporaryIcon() {
        // 取消之前的隐藏任务
        hideIconTask?.cancel()
        
        // 确保菜单栏图标可见
        statusItem.isVisible = true
        
        // 如果用户设置了隐藏图标，则在15秒后再次隐藏
        if UserDefaults.standard.bool(forKey: "hideIcon") {
            let task = DispatchWorkItem { [weak self] in
                self?.statusItem.isVisible = false
            }
            hideIconTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: task)
        }
    }

    // MARK: Click handlers

    @IBAction func launchAtLoginClicked(_ sender: NSMenuItem) {
        LaunchAtLogin.isEnabled = !LaunchAtLogin.isEnabled
        setLaunchAtLoginState()
    }

    @IBAction func toggleIconClicked(_ sender: NSMenuItem) {
        let hideIcon = !UserDefaults.standard.bool(forKey: "hideIcon")
        UserDefaults.standard.set(hideIcon, forKey: "hideIcon")
        setToggleIconState()
        
        // 取消之前的隐藏任务
        hideIconTask?.cancel()
        
        // 立即应用图标显示设置，无需重启
        if hideIcon {
            // 如果设置为隐藏图标，立即隐藏
            statusItem.isVisible = false
        } else {
            // 如果设置为显示图标，立即显示
            statusItem.isVisible = true
        }
    }

    @IBAction func quitClicked(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(self)
    }

    // MARK: Notification handlers

    func setupNotificationHandlers() {
        [
            NSWorkspace.willSleepNotification: #selector(onPowerDown(note:)),
            NSWorkspace.didWakeNotification: #selector(onPowerUp(note:))
        ].forEach { notification, sel in
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: sel, name: notification, object: nil)
        }
    }

    @objc func onPowerDown(note: NSNotification) {
        AppLog.power.info("Sleep notification received.")
        let bluetoothWasOn = isBluetoothOn()
        let wifiWasOn = isWiFiOn()
        AppLog.power.info("Stored pre-sleep wireless state. bluetoothWasOn=\(bluetoothWasOn, privacy: .public), wifiWasOn=\(wifiWasOn, privacy: .public)")
        UserDefaults.standard.set(bluetoothWasOn, forKey: bluetoothWasOnBeforeSleepKey)
        UserDefaults.standard.set(wifiWasOn, forKey: wifiWasOnBeforeSleepKey)

        if bluetoothWasOn {
            if hasBluetoothPermission() {
                setBluetooth(powerOn: false)
            } else {
                AppLog.bluetooth.warning("Skipping Bluetooth off request because Bluetooth permission is unavailable.")
            }
        } else {
            AppLog.bluetooth.info("Skipping Bluetooth off request because Bluetooth was not on before sleep.")
        }

        if wifiWasOn {
            setWiFi(powerOn: false)
        } else {
            AppLog.wifi.info("Skipping Wi-Fi off request because Wi-Fi was not on before sleep.")
        }
    }

    @objc func onPowerUp(note: NSNotification) {
        AppLog.power.info("Wake notification received.")
        let bluetoothWasOn = UserDefaults.standard.bool(forKey: bluetoothWasOnBeforeSleepKey)
        let wifiWasOn = UserDefaults.standard.bool(forKey: wifiWasOnBeforeSleepKey)
        AppLog.power.info("Loaded pre-sleep wireless state. bluetoothWasOn=\(bluetoothWasOn, privacy: .public), wifiWasOn=\(wifiWasOn, privacy: .public)")

        privilegedHelperClient.restoreHibernationModeIfNeeded()

        if bluetoothWasOn && hasBluetoothPermission() {
            setBluetooth(powerOn: true)
        } else if bluetoothWasOn {
            AppLog.bluetooth.warning("Skipping Bluetooth on request because Bluetooth permission is unavailable.")
        } else {
            AppLog.bluetooth.info("Skipping Bluetooth on request because Bluetooth was not on before sleep.")
        }

        if wifiWasOn {
            setWiFi(powerOn: true)
        } else {
            AppLog.wifi.info("Skipping Wi-Fi on request because Wi-Fi was not on before sleep.")
        }

        clearStoredPowerStates()
    }

    private func setBluetooth(powerOn: Bool) {
        AppLog.bluetooth.info("Requesting Bluetooth power state. powerOn=\(powerOn, privacy: .public)")
        IOBluetoothPreferenceSetControllerPowerState(powerOn ? 1 : 0)
        if hasBluetoothPermission() {
            let observedPowerOn = isBluetoothOn()
            AppLog.bluetooth.info("Bluetooth power request completed. requestedPowerOn=\(powerOn, privacy: .public), observedPowerOn=\(observedPowerOn, privacy: .public)")
        } else {
            AppLog.bluetooth.warning("Bluetooth power request completed, but observed state cannot be read because Bluetooth permission is unavailable.")
        }
    }

    private func isBluetoothOn() -> Bool {
        guard hasBluetoothPermission(),
              let bluetoothController = IOBluetoothHostController.default() else {
            return false
        }

        return bluetoothController.powerState == kBluetoothHCIPowerStateON
    }

    private func setWiFi(powerOn: Bool) {
        AppLog.wifi.info("Requesting Wi-Fi power state. powerOn=\(powerOn, privacy: .public)")
        guard let interface = CWWiFiClient.shared().interface() else {
            AppLog.wifi.error("No Wi-Fi interface found.")
            return
        }

        do {
            try interface.setPower(powerOn)
            AppLog.wifi.info("Wi-Fi power request completed. powerOn=\(powerOn, privacy: .public)")
        } catch {
            AppLog.wifi.error("Failed to set Wi-Fi power state. powerOn=\(powerOn, privacy: .public), error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func isWiFiOn() -> Bool {
        guard let interface = CWWiFiClient.shared().interface() else {
            return false
        }

        return interface.powerOn()
    }

    private func clearStoredPowerStates() {
        UserDefaults.standard.removeObject(forKey: bluetoothWasOnBeforeSleepKey)
        UserDefaults.standard.removeObject(forKey: wifiWasOnBeforeSleepKey)
        AppLog.power.info("Cleared stored pre-sleep wireless state.")
    }

    // MARK: Low battery hibernation

    private func setupLowBatteryMonitor() {
        powerSourceMonitor.onChange = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.handlePowerSourceSnapshot(snapshot)
            }
        }
        powerSourceMonitor.start()
    }

    private func handlePowerSourceSnapshot(_ snapshot: PowerSourceSnapshot) {
        guard snapshot.isBatteryPower,
              !snapshot.isCharging,
              snapshot.chargePercentage < LowBatteryPolicy.warningThreshold else {
            suppressedBatteryBucket = nil
            cancelLowBatteryWarning()
            return
        }

        guard lowBatteryAlert == nil,
              LowBatteryPolicy.shouldStartWarning(for: snapshot, suppressedBucket: suppressedBatteryBucket),
              let bucket = LowBatteryPolicy.bucket(for: snapshot.chargePercentage) else {
            return
        }

        showLowBatteryWarning(for: snapshot, bucket: bucket)
    }

    private func showLowBatteryWarning(for snapshot: PowerSourceSnapshot, bucket: Int) {
        lowBatteryTimedOut = false
        lowBatteryCanceled = false
        lowBatteryWarningDeadline = Date().addingTimeInterval(TimeInterval(lowBatteryCountdownSeconds))

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Battery Low", comment: "Low battery alert title")
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Low battery alert confirmation button"))
        lowBatteryAlert = alert
        updateLowBatteryAlertText(for: snapshot, remainingSeconds: lowBatteryCountdownSeconds)

        lowBatteryCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickLowBatteryCountdown(snapshot: snapshot)
        }

        let response = alert.runModal()
        lowBatteryCountdownTimer?.invalidate()
        lowBatteryCountdownTimer = nil
        lowBatteryAlert = nil
        lowBatteryWarningDeadline = nil

        if lowBatteryCanceled {
            return
        }

        if lowBatteryTimedOut {
            forceHibernateIfStillNeeded()
            return
        }

        if response == .alertFirstButtonReturn {
            suppressedBatteryBucket = bucket
        }
    }

    private func tickLowBatteryCountdown(snapshot: PowerSourceSnapshot) {
        if let currentSnapshot = powerSourceMonitor.currentSnapshot(),
           !LowBatteryPolicy.shouldStartWarning(for: currentSnapshot, suppressedBucket: nil) {
            cancelLowBatteryWarning()
            return
        }

        guard let deadline = lowBatteryWarningDeadline else {
            return
        }

        let remainingSeconds = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
        updateLowBatteryAlertText(for: snapshot, remainingSeconds: remainingSeconds)

        if remainingSeconds <= 0 {
            lowBatteryTimedOut = true
            lowBatteryCountdownTimer?.invalidate()
            lowBatteryCountdownTimer = nil
            lowBatteryAlert?.window.orderOut(nil)
            NSApp.abortModal()
        }
    }

    private func updateLowBatteryAlertText(for snapshot: PowerSourceSnapshot, remainingSeconds: Int) {
        lowBatteryAlert?.informativeText = String(
            format: NSLocalizedString(
                "Battery is at %d%%. Connect power or click OK. If there is no response in %d seconds, XSnooze will hibernate this Mac.",
                comment: "Low battery alert countdown text"
            ),
            snapshot.chargePercentage,
            remainingSeconds
        )
    }

    private func cancelLowBatteryWarning() {
        guard lowBatteryAlert != nil else {
            return
        }

        lowBatteryCanceled = true
        lowBatteryCountdownTimer?.invalidate()
        lowBatteryCountdownTimer = nil
        lowBatteryAlert?.window.orderOut(nil)
        NSApp.abortModal()
    }

    private func forceHibernateIfStillNeeded() {
        guard let snapshot = powerSourceMonitor.currentSnapshot(),
              LowBatteryPolicy.shouldStartWarning(for: snapshot, suppressedBucket: nil) else {
            AppLog.hibernate.info("Skipping forced hibernation because the low-battery condition no longer applies.")
            return
        }

        AppLog.hibernate.info("Requesting forced low-battery hibernation. chargePercentage=\(snapshot.chargePercentage, privacy: .public)")
        privilegedHelperClient.prepareHibernateAndSleep { [weak self] success, message in
            guard !success else {
                AppLog.hibernate.info("Forced low-battery hibernation request succeeded.")
                return
            }

            AppLog.hibernate.error("Failed to prepare hibernation. message=\(message ?? "Unknown error", privacy: .public)")
            self?.showHelperFailure(message: message)
        }
    }

    private func showHelperFailure(message: String?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("XSnooze Helper Required", comment: "Privileged helper failure title")
        alert.informativeText = message ?? NSLocalizedString(
            "XSnooze could not install or contact its privileged helper. Forced low-battery hibernation requires administrator approval.",
            comment: "Privileged helper failure text"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Privileged helper failure confirmation button"))
        alert.runModal()
    }

    // MARK: UI state

    private func initStatusItem() {
        // 始终先显示图标，以便用户可以访问菜单
        if let icon = NSImage(named: "bluesnooze") {
            icon.isTemplate = true
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "XSnooze"
        }
        statusItem.menu = statusMenu
        statusItem.isVisible = true // 确保图标可见
        
        // 如果用户设置了隐藏图标，则在15秒后自动隐藏
        if UserDefaults.standard.bool(forKey: "hideIcon") {
            let task = DispatchWorkItem { [weak self] in
                self?.statusItem.isVisible = false
            }
            hideIconTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: task)
        }
    }

    private func setLaunchAtLoginState() {
        let state = LaunchAtLogin.isEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        launchAtLoginMenuItem.state = state
    }
    
    private func setToggleIconState() {
        let hideIcon = UserDefaults.standard.bool(forKey: "hideIcon")
        let state = hideIcon ? NSControl.StateValue.on : NSControl.StateValue.off
        toggleIconMenuItem.state = state
    }
    
    // MARK: Bluetooth permission handling
    
    private func hasBluetoothPermission() -> Bool {
        // 检查蓝牙权限状态
        if #available(macOS 10.15, *) {
            // 在 macOS 10.15+ 上，我们需要检查蓝牙权限
            // 如果之前已经授权过，就不会再次弹出权限请求
            let bluetoothManager = IOBluetoothHostController.default()
            return bluetoothManager != nil
        } else {
            // 在较旧的 macOS 版本上，通常不需要特殊权限
            return true
        }
    }
}

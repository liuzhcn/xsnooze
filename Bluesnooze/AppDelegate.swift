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
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var launchAtLoginMenuItem: NSMenuItem!
    @IBOutlet weak var toggleIconMenuItem: NSMenuItem!

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hideIconTask: DispatchWorkItem?
    private let statusPopover = NSPopover()
    private let hideIconDelaySeconds = 15.0
    private var statusPopoverClosedAt: Date?
    private let bluetoothWasOnBeforeSleepKey = "bluetoothWasOnBeforeSleep"
    private let wifiWasOnBeforeSleepKey = "wifiWasOnBeforeSleep"
    private var cachedBluetoothWasOn = false
    private var cachedWiFiWasOn = false
    private var wirelessStateRefreshTimer: Timer?
    private var bluetoothVerificationID = 0
    private var wifiVerificationID = 0
    private let powerSourceMonitor = PowerSourceMonitor()
    private let privilegedHelperClient = PrivilegedHelperClient()
    private var lowBatteryAlert: NSAlert?
    private var lowBatteryCountdownTimer: Timer?
    private var lowBatteryWarningDeadline: Date?
    private var lowBatteryTimedOut = false
    private var lowBatteryCanceled = false
    private var suppressedBatteryBucket: Int?
    private var lowBatterySettings = LowBatterySettings(userDefaults: .standard)
    private var lowBatteryReminderMenuItem: NSMenuItem?
    private var lowBatterySettingsMenuItem: NSMenuItem?
    private var lowBatteryThresholdLabel: NSTextField?
    private var lowBatteryThresholdValueLabel: NSTextField?
    private var lowBatteryThresholdDecrementButton: NSButton?
    private var lowBatteryThresholdIncrementButton: NSButton?
    private var lowBatteryForceHibernateCheckbox: NSButton?
    private var lowBatteryCountdownLabel: NSTextField?
    private var lowBatteryCountdownValueLabel: NSTextField?
    private var lowBatteryCountdownDecrementButton: NSButton?
    private var lowBatteryCountdownIncrementButton: NSButton?
    private var launchAtLoginButton: NSButton?
    private var toggleIconButton: NSButton?
    private var lowBatteryReminderButton: NSButton?
    private var versionLabel: NSTextField?
    private let disabledLowBatteryControlAlpha = 0.45

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        initStatusItem()
        setLaunchAtLoginState()
        setToggleIconState()
        setupNotificationHandlers()
        privilegedHelperClient.restoreHibernationModeIfNeeded()
        setupWirelessStateRefresh()
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
        cancelHideIconTask()

        // 确保菜单栏图标可见
        statusItem.isVisible = true

        scheduleHideIconIfNeeded()
    }

    // MARK: Click handlers

    @IBAction func launchAtLoginClicked(_ sender: Any) {
        LaunchAtLogin.isEnabled = !LaunchAtLogin.isEnabled
        setLaunchAtLoginState()
    }

    @IBAction func toggleIconClicked(_ sender: Any) {
        let hideIcon = !UserDefaults.standard.bool(forKey: "hideIcon")
        UserDefaults.standard.set(hideIcon, forKey: "hideIcon")
        setToggleIconState()
        
        // 取消之前的隐藏任务
        cancelHideIconTask()
        
        // 立即应用图标显示设置，无需重启
        if hideIcon {
            if !statusPopover.isShown {
                statusItem.isVisible = false
            }
        } else {
            // 如果设置为显示图标，立即显示
            statusItem.isVisible = true
        }
    }

    @IBAction func quitClicked(_ sender: Any) {
        NSApplication.shared.terminate(self)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        if statusPopover.isShown {
            statusPopover.performClose(sender)
            return
        }

        if let statusPopoverClosedAt,
           Date().timeIntervalSince(statusPopoverClosedAt) < 0.25 {
            return
        }

        showStatusPopover()
    }

    @objc private func lowBatteryReminderClicked(_ sender: NSMenuItem) {
        updateLowBatterySettings(lowBatterySettings.with(isEnabled: !lowBatterySettings.isEnabled))
    }

    @objc private func lowBatteryThresholdDecrementClicked(_ sender: NSButton) {
        updateLowBatterySettings(lowBatterySettings.with(
            thresholdPercentage: LowBatterySettings.steppedValue(
                from: lowBatterySettings.thresholdPercentage,
                delta: -LowBatterySettings.adjustmentStep,
                in: LowBatterySettings.thresholdRange
            )
        ))
    }

    @objc private func lowBatteryThresholdIncrementClicked(_ sender: NSButton) {
        updateLowBatterySettings(lowBatterySettings.with(
            thresholdPercentage: LowBatterySettings.steppedValue(
                from: lowBatterySettings.thresholdPercentage,
                delta: LowBatterySettings.adjustmentStep,
                in: LowBatterySettings.thresholdRange
            )
        ))
    }

    @objc private func lowBatteryForceHibernateClicked(_ sender: NSButton) {
        updateLowBatterySettings(lowBatterySettings.with(forceHibernateOnTimeout: sender.state == .on))
    }

    @objc private func lowBatteryCountdownDecrementClicked(_ sender: NSButton) {
        updateLowBatterySettings(lowBatterySettings.with(
            countdownSeconds: LowBatterySettings.steppedValue(
                from: lowBatterySettings.countdownSeconds,
                delta: -LowBatterySettings.adjustmentStep,
                in: LowBatterySettings.countdownRange
            )
        ))
    }

    @objc private func lowBatteryCountdownIncrementClicked(_ sender: NSButton) {
        updateLowBatterySettings(lowBatterySettings.with(
            countdownSeconds: LowBatterySettings.steppedValue(
                from: lowBatterySettings.countdownSeconds,
                delta: LowBatterySettings.adjustmentStep,
                in: LowBatterySettings.countdownRange
            )
        ))
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
        AppLog.power.notice("Sleep notification received.")
        let decision = WirelessSleepPolicy.sleepActions(
            cachedBluetoothWasOn: cachedBluetoothWasOn,
            cachedWiFiWasOn: cachedWiFiWasOn,
            readCurrentBluetoothState: isBluetoothOn,
            readCurrentWiFiState: isWiFiOn
        )
        AppLog.power.notice("Stored cached pre-sleep wireless state. bluetoothWasOn=\(decision.bluetoothWasOn, privacy: .public), wifiWasOn=\(decision.wifiWasOn, privacy: .public)")
        UserDefaults.standard.set(decision.bluetoothWasOn, forKey: bluetoothWasOnBeforeSleepKey)
        UserDefaults.standard.set(decision.wifiWasOn, forKey: wifiWasOnBeforeSleepKey)

        if decision.shouldTurnBluetoothOff {
            setBluetooth(powerOn: false, verify: false)
            verifyBluetoothPowerStateAsync(requestedPowerOn: false, reason: "sleep")
        } else {
            AppLog.bluetooth.notice("Skipping Bluetooth off request because Bluetooth was not on before sleep.")
        }

        if decision.shouldTurnWiFiOff {
            setWiFi(powerOn: false, verify: false)
            verifyWiFiPowerStateAsync(requestedPowerOn: false, reason: "sleep")
        } else {
            AppLog.wifi.notice("Skipping Wi-Fi off request because Wi-Fi was not on before sleep.")
        }
    }

    @objc func onPowerUp(note: NSNotification) {
        AppLog.power.notice("Wake notification received.")
        let bluetoothWasOn = UserDefaults.standard.bool(forKey: bluetoothWasOnBeforeSleepKey)
        let wifiWasOn = UserDefaults.standard.bool(forKey: wifiWasOnBeforeSleepKey)
        AppLog.power.notice("Loaded pre-sleep wireless state. bluetoothWasOn=\(bluetoothWasOn, privacy: .public), wifiWasOn=\(wifiWasOn, privacy: .public)")

        privilegedHelperClient.restoreHibernationModeIfNeeded()

        if bluetoothWasOn {
            setBluetooth(powerOn: true, verify: false)
            verifyBluetoothPowerStateAsync(requestedPowerOn: true, reason: "wake")
        } else {
            AppLog.bluetooth.notice("Skipping Bluetooth on request because Bluetooth was not on before sleep.")
        }

        if wifiWasOn {
            setWiFi(powerOn: true, verify: false)
            verifyWiFiPowerStateAsync(requestedPowerOn: true, reason: "wake")
        } else {
            AppLog.wifi.notice("Skipping Wi-Fi on request because Wi-Fi was not on before sleep.")
        }

        clearStoredPowerStates()
        refreshWirelessStateCache(reason: "wake")
    }

    private func setBluetooth(powerOn: Bool, verify: Bool = true) {
        AppLog.bluetooth.notice("Requesting Bluetooth power state. powerOn=\(powerOn, privacy: .public)")
        IOBluetoothPreferenceSetControllerPowerState(powerOn ? 1 : 0)
        cachedBluetoothWasOn = powerOn
        if verify, hasBluetoothPermission() {
            let observedPowerOn = isBluetoothOn()
            AppLog.bluetooth.notice("Bluetooth power request completed. requestedPowerOn=\(powerOn, privacy: .public), observedPowerOn=\(observedPowerOn, privacy: .public)")
        } else if verify {
            AppLog.bluetooth.warning("Bluetooth power request completed, but observed state cannot be read because Bluetooth permission is unavailable.")
        } else {
            AppLog.bluetooth.notice("Bluetooth power request completed without immediate verification. requestedPowerOn=\(powerOn, privacy: .public)")
        }
    }

    private func isBluetoothOn() -> Bool {
        guard hasBluetoothPermission(),
              let bluetoothController = IOBluetoothHostController.default() else {
            return false
        }

        return bluetoothController.powerState == kBluetoothHCIPowerStateON
    }

    private func setWiFi(powerOn: Bool, verify: Bool = true) {
        AppLog.wifi.notice("Requesting Wi-Fi power state. powerOn=\(powerOn, privacy: .public)")
        guard let interface = CWWiFiClient.shared().interface() else {
            AppLog.wifi.error("No Wi-Fi interface found.")
            return
        }

        do {
            try interface.setPower(powerOn)
            cachedWiFiWasOn = powerOn
            if verify {
                let observedPowerOn = interface.powerOn()
                AppLog.wifi.notice("Wi-Fi power request completed. requestedPowerOn=\(powerOn, privacy: .public), observedPowerOn=\(observedPowerOn, privacy: .public)")
            } else {
                AppLog.wifi.notice("Wi-Fi power request completed without immediate verification. requestedPowerOn=\(powerOn, privacy: .public)")
            }
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

    private func verifyBluetoothPowerStateAsync(requestedPowerOn: Bool, reason: String, timeout: TimeInterval = 2.0) {
        bluetoothVerificationID += 1
        let verificationID = bluetoothVerificationID
        var completed = false

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let observedPowerOn = self?.isBluetoothOn() ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.bluetoothVerificationID == verificationID, !completed else {
                    return
                }

                completed = true
                self.cachedBluetoothWasOn = observedPowerOn
                AppLog.bluetooth.notice("Bluetooth power verification completed. reason=\(reason, privacy: .public), requestedPowerOn=\(requestedPowerOn, privacy: .public), observedPowerOn=\(observedPowerOn, privacy: .public)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.bluetoothVerificationID == verificationID, !completed else {
                return
            }

            completed = true
            AppLog.bluetooth.warning("Bluetooth power verification timed out. reason=\(reason, privacy: .public), requestedPowerOn=\(requestedPowerOn, privacy: .public), timeoutSeconds=\(timeout, privacy: .public)")
        }
    }

    private func verifyWiFiPowerStateAsync(requestedPowerOn: Bool, reason: String, timeout: TimeInterval = 2.0) {
        wifiVerificationID += 1
        let verificationID = wifiVerificationID
        var completed = false

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let observedPowerOn = self?.isWiFiOn() ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wifiVerificationID == verificationID, !completed else {
                    return
                }

                completed = true
                self.cachedWiFiWasOn = observedPowerOn
                AppLog.wifi.notice("Wi-Fi power verification completed. reason=\(reason, privacy: .public), requestedPowerOn=\(requestedPowerOn, privacy: .public), observedPowerOn=\(observedPowerOn, privacy: .public)")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.wifiVerificationID == verificationID, !completed else {
                return
            }

            completed = true
            AppLog.wifi.warning("Wi-Fi power verification timed out. reason=\(reason, privacy: .public), requestedPowerOn=\(requestedPowerOn, privacy: .public), timeoutSeconds=\(timeout, privacy: .public)")
        }
    }

    private func setupWirelessStateRefresh() {
        refreshWirelessStateCache(reason: "launch")
        wirelessStateRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.refreshWirelessStateCache(reason: "timer")
        }
    }

    private func refreshWirelessStateCache(reason: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }

            let bluetoothWasOn = self.isBluetoothOn()
            let wifiWasOn = self.isWiFiOn()

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }

                self.cachedBluetoothWasOn = bluetoothWasOn
                self.cachedWiFiWasOn = wifiWasOn
                AppLog.power.info("Refreshed wireless state cache. reason=\(reason, privacy: .public), bluetoothWasOn=\(bluetoothWasOn, privacy: .public), wifiWasOn=\(wifiWasOn, privacy: .public)")
            }
        }
    }

    private func clearStoredPowerStates() {
        UserDefaults.standard.removeObject(forKey: bluetoothWasOnBeforeSleepKey)
        UserDefaults.standard.removeObject(forKey: wifiWasOnBeforeSleepKey)
        AppLog.power.notice("Cleared stored pre-sleep wireless state.")
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
        guard lowBatterySettings.isEnabled,
              snapshot.isBatteryPower,
              !snapshot.isCharging,
              LowBatteryPolicy.bucket(for: snapshot.chargePercentage, settings: lowBatterySettings) != nil else {
            suppressedBatteryBucket = nil
            cancelLowBatteryWarning()
            return
        }

        guard lowBatteryAlert == nil,
              LowBatteryPolicy.shouldStartWarning(for: snapshot, settings: lowBatterySettings, suppressedBucket: suppressedBatteryBucket),
              let bucket = LowBatteryPolicy.bucket(for: snapshot.chargePercentage, settings: lowBatterySettings) else {
            return
        }

        showLowBatteryWarning(for: snapshot, bucket: bucket)
    }

    private func showLowBatteryWarning(for snapshot: PowerSourceSnapshot, bucket: Int) {
        lowBatteryTimedOut = false
        lowBatteryCanceled = false
        lowBatteryWarningDeadline = Date().addingTimeInterval(TimeInterval(lowBatterySettings.countdownSeconds))

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Battery Low", comment: "Low battery alert title")
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Low battery alert confirmation button"))
        lowBatteryAlert = alert
        updateLowBatteryAlertText(for: snapshot, remainingSeconds: lowBatterySettings.countdownSeconds)

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
            if lowBatterySettings.forceHibernateOnTimeout {
                forceHibernateIfStillNeeded()
            } else {
                suppressedBatteryBucket = bucket
            }
            return
        }

        if response == .alertFirstButtonReturn {
            suppressedBatteryBucket = bucket
        }
    }

    private func tickLowBatteryCountdown(snapshot: PowerSourceSnapshot) {
        if let currentSnapshot = powerSourceMonitor.currentSnapshot(),
           !LowBatteryPolicy.shouldStartWarning(for: currentSnapshot, settings: lowBatterySettings, suppressedBucket: nil) {
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
        if lowBatterySettings.forceHibernateOnTimeout {
            lowBatteryAlert?.informativeText = String(
                format: NSLocalizedString(
                    "Battery is at %d%%. Connect power or click OK. If there is no response in %d seconds, XSnooze will hibernate this Mac.",
                    comment: "Low battery alert countdown text"
                ),
                snapshot.chargePercentage,
                remainingSeconds
            )
        } else {
            lowBatteryAlert?.informativeText = String(
                format: NSLocalizedString(
                    "Battery is at %d%%. Connect power or click OK. If there is no response in %d seconds, XSnooze will close this reminder.",
                    comment: "Low battery alert countdown text without hibernation"
                ),
                snapshot.chargePercentage,
                remainingSeconds
            )
        }
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
              LowBatteryPolicy.shouldStartWarning(for: snapshot, settings: lowBatterySettings, suppressedBucket: nil) else {
            AppLog.hibernate.notice("Skipping forced hibernation because the low-battery condition no longer applies.")
            return
        }

        AppLog.hibernate.notice("Requesting forced low-battery hibernation. chargePercentage=\(snapshot.chargePercentage, privacy: .public)")
        privilegedHelperClient.prepareHibernateAndSleep { [weak self] success, message in
            guard !success else {
                AppLog.hibernate.notice("Forced low-battery hibernation request succeeded.")
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
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.isVisible = true // 确保图标可见
        setupStatusPopover()
        scheduleHideIconIfNeeded()
    }

    private func setLaunchAtLoginState() {
        let state = LaunchAtLogin.isEnabled ? NSControl.StateValue.on : NSControl.StateValue.off
        launchAtLoginMenuItem.state = state
        launchAtLoginButton?.state = state
    }
    
    private func setToggleIconState() {
        let hideIcon = UserDefaults.standard.bool(forKey: "hideIcon")
        let state = hideIcon ? NSControl.StateValue.on : NSControl.StateValue.off
        toggleIconMenuItem.state = state
        toggleIconButton?.state = state
    }

    private func setupStatusPopover() {
        statusPopover.behavior = .transient
        statusPopover.delegate = self
        statusPopover.contentViewController = NSViewController()
        statusPopover.contentViewController?.view = makeStatusPopoverView()
    }

    private func showStatusPopover() {
        guard let button = statusItem.button else {
            return
        }

        statusItem.isVisible = true
        cancelHideIconTask()
        setLaunchAtLoginState()
        setToggleIconState()
        setLowBatteryMenuState()
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        statusPopoverClosedAt = Date()
        scheduleHideIconIfNeeded()
    }

    private func cancelHideIconTask() {
        hideIconTask?.cancel()
        hideIconTask = nil
    }

    private func scheduleHideIconIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "hideIcon"),
              !statusPopover.isShown else {
            return
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.statusPopover.isShown else {
                return
            }

            self.statusItem.isVisible = false
            self.hideIconTask = nil
        }
        hideIconTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + hideIconDelaySeconds, execute: task)
    }

    private func makeStatusPopoverView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 236))

        let launchButton = makeMenuCheckbox(
            title: NSLocalizedString("Launch at login", comment: "Launch at login menu item"),
            action: #selector(launchAtLoginClicked(_:))
        )
        launchButton.frame = NSRect(x: 14, y: 200, width: 292, height: 22)
        view.addSubview(launchButton)

        let toggleIconButton = makeMenuCheckbox(
            title: NSLocalizedString("Hide menu bar icon", comment: "Hide menu bar icon menu item"),
            action: #selector(toggleIconClicked(_:))
        )
        toggleIconButton.frame = NSRect(x: 14, y: 172, width: 292, height: 22)
        view.addSubview(toggleIconButton)

        view.addSubview(makeSeparator(frame: NSRect(x: 0, y: 158, width: 320, height: 1)))

        let lowBatteryReminderButton = makeMenuCheckbox(
            title: NSLocalizedString("Low Battery Reminder", comment: "Low battery reminder menu item"),
            action: #selector(lowBatteryReminderClicked(_:))
        )
        lowBatteryReminderButton.frame = NSRect(x: 14, y: 130, width: 292, height: 22)
        view.addSubview(lowBatteryReminderButton)

        let thresholdLabel = makeLowBatteryLabel()
        thresholdLabel.frame = NSRect(x: 42, y: 102, width: 160, height: 18)
        view.addSubview(thresholdLabel)

        let thresholdStepper = makeLowBatteryStepper(
            valueWidth: 42,
            decrementAction: #selector(lowBatteryThresholdDecrementClicked(_:)),
            incrementAction: #selector(lowBatteryThresholdIncrementClicked(_:))
        )
        thresholdStepper.decrementButton.frame.origin = NSPoint(x: 204, y: 96)
        thresholdStepper.valueLabel.frame.origin = NSPoint(x: 236, y: 99)
        thresholdStepper.incrementButton.frame.origin = NSPoint(x: 284, y: 96)
        view.addSubview(thresholdStepper.decrementButton)
        view.addSubview(thresholdStepper.valueLabel)
        view.addSubview(thresholdStepper.incrementButton)

        let forceHibernateCheckbox = NSButton(
            checkboxWithTitle: NSLocalizedString("Hibernate if no response", comment: "Low battery force hibernation checkbox"),
            target: self,
            action: #selector(lowBatteryForceHibernateClicked(_:))
        )
        forceHibernateCheckbox.font = .menuFont(ofSize: 13)
        forceHibernateCheckbox.frame = NSRect(x: 40, y: 72, width: 266, height: 20)
        view.addSubview(forceHibernateCheckbox)

        let countdownLabel = makeLowBatteryLabel()
        countdownLabel.frame = NSRect(x: 42, y: 46, width: 160, height: 18)
        view.addSubview(countdownLabel)

        let countdownStepper = makeLowBatteryStepper(
            valueWidth: 50,
            decrementAction: #selector(lowBatteryCountdownDecrementClicked(_:)),
            incrementAction: #selector(lowBatteryCountdownIncrementClicked(_:))
        )
        countdownStepper.decrementButton.frame.origin = NSPoint(x: 196, y: 40)
        countdownStepper.valueLabel.frame.origin = NSPoint(x: 228, y: 43)
        countdownStepper.incrementButton.frame.origin = NSPoint(x: 284, y: 40)
        view.addSubview(countdownStepper.decrementButton)
        view.addSubview(countdownStepper.valueLabel)
        view.addSubview(countdownStepper.incrementButton)

        view.addSubview(makeSeparator(frame: NSRect(x: 0, y: 32, width: 320, height: 1)))

        let quitButton = NSButton(
            title: NSLocalizedString("Quit", comment: "Quit menu item"),
            target: self,
            action: #selector(quitClicked(_:))
        )
        quitButton.isBordered = false
        quitButton.alignment = .left
        quitButton.font = .menuFont(ofSize: 13)
        quitButton.frame = NSRect(x: 18, y: 2, width: 140, height: 28)
        view.addSubview(quitButton)

        let versionLabel = NSTextField(labelWithString: appVersionText())
        versionLabel.alignment = .right
        versionLabel.font = .menuFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 168, y: 7, width: 126, height: 18)
        view.addSubview(versionLabel)

        self.launchAtLoginButton = launchButton
        self.toggleIconButton = toggleIconButton
        self.lowBatteryReminderButton = lowBatteryReminderButton
        self.versionLabel = versionLabel
        lowBatteryThresholdLabel = thresholdLabel
        lowBatteryThresholdValueLabel = thresholdStepper.valueLabel
        lowBatteryThresholdDecrementButton = thresholdStepper.decrementButton
        lowBatteryThresholdIncrementButton = thresholdStepper.incrementButton
        lowBatteryForceHibernateCheckbox = forceHibernateCheckbox
        lowBatteryCountdownLabel = countdownLabel
        lowBatteryCountdownValueLabel = countdownStepper.valueLabel
        lowBatteryCountdownDecrementButton = countdownStepper.decrementButton
        lowBatteryCountdownIncrementButton = countdownStepper.incrementButton

        return view
    }

    private func makeMenuCheckbox(title: String, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.font = .menuFont(ofSize: 13)
        return button
    }

    private func makeSeparator(frame: NSRect) -> NSBox {
        let separator = NSBox(frame: frame)
        separator.boxType = .separator
        return separator
    }

    private func appVersionText() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.6.0"
        return "v\(version)"
    }

    private func makeLowBatteryLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .menuFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeLowBatteryStepper(
        valueWidth: CGFloat,
        decrementAction: Selector,
        incrementAction: Selector
    ) -> (decrementButton: NSButton, valueLabel: NSTextField, incrementButton: NSButton) {
        let decrementButton = makeStepButton(title: "-", action: decrementAction)
        let valueLabel = NSTextField(labelWithString: "")
        valueLabel.alignment = .center
        valueLabel.font = .menuFont(ofSize: 13)
        valueLabel.frame.size = NSSize(width: valueWidth, height: 18)
        let incrementButton = makeStepButton(title: "+", action: incrementAction)
        return (decrementButton, valueLabel, incrementButton)
    }

    private func makeStepButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .menuFont(ofSize: 15)
        button.alignment = .center
        button.frame.size = NSSize(width: 28, height: 24)
        return button
    }

    private func updateLowBatterySettings(_ settings: LowBatterySettings) {
        lowBatterySettings = settings
        settings.save(to: .standard)
        setLowBatteryMenuState()

        if !settings.isEnabled {
            suppressedBatteryBucket = nil
            cancelLowBatteryWarning()
            return
        }

        guard let snapshot = powerSourceMonitor.currentSnapshot() else {
            return
        }

        if !LowBatteryPolicy.shouldStartWarning(for: snapshot, settings: settings, suppressedBucket: nil) {
            suppressedBatteryBucket = nil
            cancelLowBatteryWarning()
        } else if lowBatteryAlert != nil {
            let remainingSeconds = lowBatteryWarningDeadline.map { max(0, Int(ceil($0.timeIntervalSinceNow))) } ?? settings.countdownSeconds
            updateLowBatteryAlertText(for: snapshot, remainingSeconds: remainingSeconds)
        } else {
            handlePowerSourceSnapshot(snapshot)
        }
    }

    private func setLowBatteryMenuState() {
        lowBatteryReminderMenuItem?.state = lowBatterySettings.isEnabled ? .on : .off
        lowBatteryReminderButton?.state = lowBatterySettings.isEnabled ? .on : .off
        lowBatteryThresholdLabel?.stringValue = NSLocalizedString("Battery alert threshold", comment: "Low battery threshold setting label")
        lowBatteryThresholdValueLabel?.stringValue = String(
            format: NSLocalizedString("%d%%", comment: "Low battery threshold value"),
            lowBatterySettings.thresholdPercentage
        )
        lowBatteryForceHibernateCheckbox?.state = lowBatterySettings.forceHibernateOnTimeout ? .on : .off
        lowBatteryCountdownLabel?.stringValue = NSLocalizedString("No response countdown", comment: "Low battery countdown setting label")
        lowBatteryCountdownValueLabel?.stringValue = String(
            format: NSLocalizedString("%ds", comment: "Low battery countdown value"),
            lowBatterySettings.countdownSeconds
        )

        applyLowBatteryState(
            isEnabled: lowBatterySettings.isEnabled,
            label: lowBatteryThresholdLabel,
            valueLabel: lowBatteryThresholdValueLabel,
            decrementButton: lowBatteryThresholdDecrementButton,
            incrementButton: lowBatteryThresholdIncrementButton,
            value: lowBatterySettings.thresholdPercentage,
            range: LowBatterySettings.thresholdRange
        )

        lowBatteryForceHibernateCheckbox?.isEnabled = lowBatterySettings.isEnabled
        lowBatteryForceHibernateCheckbox?.alphaValue = lowBatterySettings.isEnabled ? 1.0 : disabledLowBatteryControlAlpha

        applyLowBatteryState(
            isEnabled: lowBatterySettings.canEditCountdown,
            label: lowBatteryCountdownLabel,
            valueLabel: lowBatteryCountdownValueLabel,
            decrementButton: lowBatteryCountdownDecrementButton,
            incrementButton: lowBatteryCountdownIncrementButton,
            value: lowBatterySettings.countdownSeconds,
            range: LowBatterySettings.countdownRange
        )

        versionLabel?.stringValue = appVersionText()
    }

    private func applyLowBatteryState(
        isEnabled: Bool,
        label: NSTextField?,
        valueLabel: NSTextField?,
        decrementButton: NSButton?,
        incrementButton: NSButton?,
        value: Int,
        range: ClosedRange<Int>
    ) {
        label?.isEnabled = isEnabled
        label?.alphaValue = 1.0
        label?.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        valueLabel?.isEnabled = isEnabled
        valueLabel?.alphaValue = 1.0
        valueLabel?.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        decrementButton?.isEnabled = isEnabled && value > range.lowerBound
        incrementButton?.isEnabled = isEnabled && value < range.upperBound
        decrementButton?.alphaValue = decrementButton?.isEnabled == true ? 1.0 : disabledLowBatteryControlAlpha
        incrementButton?.alphaValue = incrementButton?.isEnabled == true ? 1.0 : disabledLowBatteryControlAlpha
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

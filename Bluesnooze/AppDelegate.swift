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
    private var lowBatteryThresholdSlider: NSSlider?
    private var lowBatteryForceHibernateCheckbox: NSButton?
    private var lowBatteryCountdownLabel: NSTextField?
    private var lowBatteryCountdownSlider: NSSlider?
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

    @objc private func lowBatteryThresholdChanged(_ sender: NSSlider) {
        updateLowBatterySettings(lowBatterySettings.with(thresholdPercentage: sender.integerValue))
    }

    @objc private func lowBatteryForceHibernateClicked(_ sender: NSButton) {
        updateLowBatterySettings(lowBatterySettings.with(forceHibernateOnTimeout: sender.state == .on))
    }

    @objc private func lowBatteryCountdownChanged(_ sender: NSSlider) {
        updateLowBatterySettings(lowBatterySettings.with(countdownSeconds: sender.integerValue))
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
        thresholdLabel.frame = NSRect(x: 42, y: 102, width: 132, height: 18)
        view.addSubview(thresholdLabel)

        let thresholdSlider = makeLowBatterySlider(
            minValue: Double(LowBatterySettings.thresholdRange.lowerBound),
            maxValue: Double(LowBatterySettings.thresholdRange.upperBound),
            action: #selector(lowBatteryThresholdChanged(_:))
        )
        thresholdSlider.frame = NSRect(x: 180, y: 99, width: 114, height: 24)
        view.addSubview(thresholdSlider)

        let forceHibernateCheckbox = NSButton(
            checkboxWithTitle: NSLocalizedString("Hibernate if no response", comment: "Low battery force hibernation checkbox"),
            target: self,
            action: #selector(lowBatteryForceHibernateClicked(_:))
        )
        forceHibernateCheckbox.font = .menuFont(ofSize: 13)
        forceHibernateCheckbox.frame = NSRect(x: 40, y: 72, width: 266, height: 20)
        view.addSubview(forceHibernateCheckbox)

        let countdownLabel = makeLowBatteryLabel()
        countdownLabel.frame = NSRect(x: 42, y: 46, width: 132, height: 18)
        view.addSubview(countdownLabel)

        let countdownSlider = makeLowBatterySlider(
            minValue: Double(LowBatterySettings.countdownRange.lowerBound),
            maxValue: Double(LowBatterySettings.countdownRange.upperBound),
            action: #selector(lowBatteryCountdownChanged(_:))
        )
        countdownSlider.frame = NSRect(x: 180, y: 43, width: 114, height: 24)
        view.addSubview(countdownSlider)

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
        lowBatteryThresholdSlider = thresholdSlider
        lowBatteryForceHibernateCheckbox = forceHibernateCheckbox
        lowBatteryCountdownLabel = countdownLabel
        lowBatteryCountdownSlider = countdownSlider

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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5.2"
        return "v\(version)"
    }

    private func makeLowBatteryLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .menuFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func makeLowBatterySlider(minValue: Double, maxValue: Double, action: Selector) -> NSSlider {
        let slider = NSSlider(value: minValue, minValue: minValue, maxValue: maxValue, target: self, action: action)
        slider.isContinuous = true
        return slider
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
        lowBatteryThresholdLabel?.stringValue = String(
            format: NSLocalizedString("Remind below %d%%", comment: "Low battery threshold label"),
            lowBatterySettings.thresholdPercentage
        )
        lowBatteryThresholdSlider?.integerValue = lowBatterySettings.thresholdPercentage
        lowBatteryForceHibernateCheckbox?.state = lowBatterySettings.forceHibernateOnTimeout ? .on : .off
        lowBatteryCountdownLabel?.stringValue = String(
            format: NSLocalizedString("Countdown %ds", comment: "Low battery countdown label"),
            lowBatterySettings.countdownSeconds
        )
        lowBatteryCountdownSlider?.integerValue = lowBatterySettings.countdownSeconds

        applyLowBatteryState(
            isEnabled: lowBatterySettings.isEnabled,
            label: lowBatteryThresholdLabel,
            slider: lowBatteryThresholdSlider
        )

        lowBatteryForceHibernateCheckbox?.isEnabled = lowBatterySettings.isEnabled
        lowBatteryForceHibernateCheckbox?.alphaValue = 1.0

        applyLowBatteryState(
            isEnabled: lowBatterySettings.canEditCountdown,
            label: lowBatteryCountdownLabel,
            slider: lowBatteryCountdownSlider
        )

        versionLabel?.stringValue = appVersionText()
    }

    private func applyLowBatteryState(isEnabled: Bool, label: NSTextField?, slider: NSSlider?) {
        label?.isEnabled = isEnabled
        label?.alphaValue = 1.0
        label?.textColor = isEnabled ? .labelColor : .disabledControlTextColor
        slider?.isEnabled = isEnabled
        slider?.alphaValue = isEnabled ? 1.0 : disabledLowBatteryControlAlpha
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

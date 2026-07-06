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
import IOKit.pwr_mgt
import LaunchAtLogin
import OSLog

private enum AppLog {
    static let power = Logger(subsystem: "com.liuzhcn.XSnooze", category: "power")
    static let bluetooth = Logger(subsystem: "com.liuzhcn.XSnooze", category: "bluetooth")
    static let wifi = Logger(subsystem: "com.liuzhcn.XSnooze", category: "wifi")
    static let hibernate = Logger(subsystem: "com.liuzhcn.XSnooze", category: "hibernate")
}

private enum IOKitPowerMessage {
    // Swift cannot import these IOMessage.h macros because they expand through helper macros.
    static let canSystemSleep: UInt32 = 0xe0000270
    static let systemWillSleep: UInt32 = 0xe0000280
    static let systemHasPoweredOn: UInt32 = 0xe0000300
}

private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class HoverMenuRowControl: NSControl {
    private weak var checkmarkLabel: NSTextField?
    private weak var titleLabel: NSTextField?
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else {
                return
            }
            updateTextColors()
            needsDisplay = true
        }
    }

    init(checkmarkLabel: NSTextField?, titleLabel: NSTextField?, target: AnyObject, action: Selector) {
        self.checkmarkLabel = checkmarkLabel
        self.titleLabel = titleLabel
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isEnabled: Bool {
        didSet {
            updateTextColors()
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = isEnabled
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isHovered, isEnabled else {
            return
        }

        NSColor(srgbRed: 0.35, green: 0.63, blue: 0.95, alpha: 1.0).setFill()
        bounds.roundedPath(radius: 7).fill()
    }

    private func updateTextColors() {
        let textColor: NSColor
        if !isEnabled {
            textColor = .disabledControlTextColor
        } else {
            textColor = isHovered ? .selectedMenuItemTextColor : .labelColor
        }

        checkmarkLabel?.textColor = textColor
        titleLabel?.textColor = textColor
    }
}

private final class HoverStepButton: NSButton {
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else {
                return
            }
            updateTitleColor()
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet {
            updateTitleColor()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = isEnabled
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered, isEnabled {
            NSColor(srgbRed: 0.35, green: 0.63, blue: 0.95, alpha: 1.0).setFill()
            bounds.insetBy(dx: 3, dy: 2).roundedPath(radius: 5).fill()
        }
        drawCenteredSymbol()
    }

    private func updateTitleColor() {
        needsDisplay = true
    }

    private func drawCenteredSymbol() {
        let color: NSColor = isHovered && isEnabled ? .selectedMenuItemTextColor : (isEnabled ? .labelColor : .disabledControlTextColor)
        let symbol = title == "-" ? "−" : title
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .regular),
            .foregroundColor: color
        ]
        let size = symbol.size(withAttributes: attributes)
        let origin = NSPoint(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2 - 0.5
        )
        symbol.draw(at: origin, withAttributes: attributes)
    }
}

private extension NSRect {
    func roundedPath(radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: self, xRadius: radius, yRadius: radius)
    }
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
    private var popoverEventMonitor: Any?
    private var popoverGlobalEventMonitor: Any?
    private let bluetoothWasOnBeforeSleepKey = "bluetoothWasOnBeforeSleep"
    private let wifiWasOnBeforeSleepKey = "wifiWasOnBeforeSleep"
    private var cachedBluetoothWasOn: Bool?
    private var cachedWiFiWasOn: Bool?
    private var wirelessStateMonitor: WirelessStateMonitor?
    private var powerNotificationPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var rootPowerPort: io_connect_t = 0
    private var powerEventRouter = PowerEventRouter(duplicateWindow: 5.0, iokitNotificationsAvailable: false)
    private lazy var bluetoothPowerController = BluetoothPowerController(
        preferencesAvailable: { IOBluetoothPreferencesAvailable() != 0 },
        getPowerState: { IOBluetoothPreferenceGetControllerPowerState() },
        setPowerState: { IOBluetoothPreferenceSetControllerPowerState($0) },
        wait: { Thread.sleep(forTimeInterval: $0) }
    )
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
    private var lowBatteryForceHibernateCheckbox: NSControl?
    private var lowBatteryCountdownLabel: NSTextField?
    private var lowBatteryCountdownValueLabel: NSTextField?
    private var lowBatteryCountdownDecrementButton: NSButton?
    private var lowBatteryCountdownIncrementButton: NSButton?
    private var launchAtLoginButton: NSControl?
    private var toggleIconButton: NSControl?
    private var lowBatteryReminderButton: NSControl?
    private var launchAtLoginCheckmark: NSTextField?
    private var toggleIconCheckmark: NSTextField?
    private var lowBatteryReminderCheckmark: NSTextField?
    private var lowBatteryForceHibernateCheckmark: NSTextField?
    private var lowBatteryForceHibernateTitleLabel: NSTextField?
    private var versionLabel: NSTextField?
    private var logsWindow: NSWindow?
    private var logsTextView: NSTextView?
    private var logsRefreshButton: NSButton?
    private var logsCopyButton: NSButton?
    private let disabledLowBatteryControlAlpha = 0.45

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        initStatusItem()
        setLaunchAtLoginState()
        setToggleIconState()
        setupNotificationHandlers()
        privilegedHelperClient.restoreHibernationModeIfNeeded()
        setupWirelessStateMonitor()
        setupLowBatteryMonitor()
    }
    
    // 处理应用程序被再次打开的情况
    func applicationWillBecomeActive(_ notification: Notification) {
        showTemporaryIcon()
    }

    func applicationDidResignActive(_ notification: Notification) {
        closeStatusPopoverIfNeeded()
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

    @objc private func showLogsClicked(_ sender: Any?) {
        statusPopover.performClose(sender)
        showLogsWindow()
    }

    @objc private func refreshLogsClicked(_ sender: Any?) {
        refreshLogsWindow()
    }

    @objc private func copyLogsClicked(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logsTextView?.string ?? "", forType: .string)
    }

    @objc private func closeLogsClicked(_ sender: Any?) {
        logsWindow?.close()
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
        updateLowBatterySettings(lowBatterySettings.with(forceHibernateOnTimeout: !lowBatterySettings.forceHibernateOnTimeout))
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
        setupIOKitPowerNotifications()
    }

    @objc func onPowerDown(note: NSNotification) {
        let decision = powerEventRouter.sleepDecision(source: .nsWorkspace)
        handleSleepDecision(decision)
    }

    @objc func onPowerUp(note: NSNotification) {
        let decision = powerEventRouter.wakeDecision(source: .nsWorkspace)
        handleWakeDecision(decision)
    }

    private func setupIOKitPowerNotifications() {
        guard powerNotificationPort == nil else {
            return
        }

        rootPowerPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &powerNotificationPort,
            { refCon, _, messageType, messageArgument in
                guard let refCon else {
                    return
                }

                let delegate = Unmanaged<AppDelegate>.fromOpaque(refCon).takeUnretainedValue()
                delegate.handleIOKitPowerMessage(type: messageType, argument: messageArgument)
            },
            &powerNotifier
        )

        guard rootPowerPort != 0,
              let powerNotificationPort,
              let runLoopSource = IONotificationPortGetRunLoopSource(powerNotificationPort)?.takeUnretainedValue() else {
            powerEventRouter.setIOKitNotificationsAvailable(false)
            AppLog.power.error("Failed to register IOKit power notifications.")
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        powerEventRouter.setIOKitNotificationsAvailable(true)
        AppLog.power.notice("Registered IOKit power notifications.")
    }

    private func handleIOKitPowerMessage(type: UInt32, argument: UnsafeMutableRawPointer?) {
        switch type {
        case IOKitPowerMessage.canSystemSleep:
            AppLog.power.notice("Can system sleep notification received from IOKit.")
            allowIOKitPowerChange(argument: argument)
        case IOKitPowerMessage.systemWillSleep:
            let decision = powerEventRouter.sleepDecision(source: .iokit)
            handleSleepDecision(decision)
            allowIOKitPowerChange(argument: argument)
        case IOKitPowerMessage.systemHasPoweredOn:
            let decision = powerEventRouter.wakeDecision(source: .iokit)
            handleWakeDecision(decision)
        default:
            break
        }
    }

    private func allowIOKitPowerChange(argument: UnsafeMutableRawPointer?) {
        guard rootPowerPort != 0 else {
            return
        }

        let result = IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        if result != kIOReturnSuccess {
            AppLog.power.warning("Failed to allow IOKit power change. result=\(result, privacy: .public)")
        }
    }

    private func handleSleepDecision(_ decision: SleepPowerEventDecision) {
        if decision.isDuplicate {
            AppLog.power.notice("Skipping duplicate sleep notification. source=\(decision.handlerSource, privacy: .public)")
            return
        }

        if decision.isDiagnosticOnly {
            AppLog.power.notice("NSWorkspace sleep notification received for diagnostics only. source=\(decision.handlerSource, privacy: .public), iokitNotificationsAvailable=\(decision.iokitNotificationsAvailable, privacy: .public), iokitSleepObserved=\(decision.iokitSleepObserved, privacy: .public), skippedWirelessHandling=true")
            return
        }

        AppLog.power.notice("Sleep notification received. source=\(decision.handlerSource, privacy: .public), iokitNotificationsAvailable=\(decision.iokitNotificationsAvailable, privacy: .public), iokitSleepObserved=\(decision.iokitSleepObserved, privacy: .public), skippedWirelessHandling=false")
        handleWirelessSleep(source: decision.handlerSource)
    }

    private func handleWirelessSleep(source: String) {
        let decision = WirelessSleepPolicy.sleepActions(
            cachedBluetoothWasOn: cachedBluetoothWasOn,
            cachedWiFiWasOn: cachedWiFiWasOn
        )
        storePreSleepWirelessState(decision)

        if decision.shouldTurnBluetoothOff {
            setBluetoothPower(false, reason: "sleep", source: source)
        } else {
            logSkippedBluetoothSleepAction(state: decision.bluetoothWasOn)
        }

        if decision.shouldTurnWiFiOff {
            setWiFi(powerOn: false, verify: true)
        } else {
            logSkippedWiFiSleepAction(state: decision.wifiWasOn)
        }
    }

    private func handleWakeDecision(_ decision: WakePowerEventDecision) {
        if decision.isDuplicate {
            AppLog.power.notice("Skipping duplicate wake notification. source=\(decision.handlerSource, privacy: .public)")
            return
        }

        if decision.isDiagnosticOnly {
            AppLog.power.notice("Wake notification received for diagnostics only. source=\(decision.handlerSource, privacy: .public), skippedWirelessRestore=true")
            return
        }

        AppLog.power.notice("Wake notification received. source=\(decision.handlerSource, privacy: .public), skippedWirelessRestore=false")
        handleWirelessWake()
    }

    private func handleWirelessWake() {
        let bluetoothWasOn = storedBool(forKey: bluetoothWasOnBeforeSleepKey)
        let wifiWasOn = storedBool(forKey: wifiWasOnBeforeSleepKey)
        AppLog.power.notice("Loaded pre-sleep wireless state. bluetoothWasOn=\(self.stateDescription(bluetoothWasOn), privacy: .public), wifiWasOn=\(self.stateDescription(wifiWasOn), privacy: .public)")

        privilegedHelperClient.restoreHibernationModeIfNeeded()

        switch bluetoothWasOn {
        case true:
            if cachedBluetoothWasOn == true {
                AppLog.bluetooth.notice("Skipping Bluetooth on request because Bluetooth is already on according to CoreBluetooth cache.")
            } else {
                setBluetoothPower(true, reason: "wake", source: "NSWorkspace")
            }
        case false:
            AppLog.bluetooth.notice("Skipping Bluetooth on request because Bluetooth was off before sleep.")
        case nil:
            AppLog.bluetooth.notice("Skipping Bluetooth on request because pre-sleep Bluetooth state is unknown.")
        }

        switch wifiWasOn {
        case true:
            setWiFi(powerOn: true, verify: false)
        case false:
            AppLog.wifi.notice("Skipping Wi-Fi on request because Wi-Fi was off before sleep.")
        case nil:
            AppLog.wifi.notice("Skipping Wi-Fi on request because pre-sleep Wi-Fi state is unknown.")
        }

        clearStoredPowerStates()
    }

    private func setBluetoothPower(_ powerOn: Bool, reason: String, source: String) {
        AppLog.bluetooth.notice("Requesting Bluetooth power state. reason=\(reason, privacy: .public), source=\(source, privacy: .public), powerOn=\(powerOn, privacy: .public)")
        let forceSetter = reason == "sleep"
        let minimumWaitAfterSetter = forceSetter ? 1.0 : 0
        let result = bluetoothPowerController.setPower(
            powerOn,
            timeout: 3.0,
            pollInterval: 0.1,
            forceSetter: forceSetter,
            minimumWaitAfterSetter: minimumWaitAfterSetter
        )

        switch result.status {
        case .unavailable:
            AppLog.bluetooth.error("Bluetooth power request failed because IOBluetooth preferences are unavailable. reason=\(reason, privacy: .public), requestedPowerOn=\(powerOn, privacy: .public)")
        case .alreadyInState:
            cachedBluetoothWasOn = powerOn
            AppLog.bluetooth.notice("Bluetooth power request skipped because state already matched. reason=\(reason, privacy: .public), requestedPowerOn=\(powerOn, privacy: .public), observedPowerOn=\(self.stateDescription(result.observedPowerOn), privacy: .public)")
        case .changed:
            cachedBluetoothWasOn = powerOn
            AppLog.bluetooth.notice("Bluetooth power request completed. reason=\(reason, privacy: .public), requestedPowerOn=\(powerOn, privacy: .public), observedPowerOn=\(self.stateDescription(result.observedPowerOn), privacy: .public), elapsedSeconds=\(result.elapsed, privacy: .public)")
        case .timedOut:
            AppLog.bluetooth.warning("Bluetooth power request timed out. reason=\(reason, privacy: .public), requestedPowerOn=\(powerOn, privacy: .public), observedPowerOn=\(self.stateDescription(result.observedPowerOn), privacy: .public), timeoutSeconds=3.0")
        }
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

    private func clearStoredPowerStates() {
        UserDefaults.standard.removeObject(forKey: bluetoothWasOnBeforeSleepKey)
        UserDefaults.standard.removeObject(forKey: wifiWasOnBeforeSleepKey)
        AppLog.power.notice("Cleared stored pre-sleep wireless state.")
    }

    private func setupWirelessStateMonitor() {
        cachedBluetoothWasOn = WirelessSleepPolicy.initialBluetoothCacheState(preferencePowerOn: nil)
        AppLog.bluetooth.notice("Initial Bluetooth cache is unknown until CoreBluetooth reports a powered state.")

        let monitor = WirelessStateMonitor()
        monitor.onBluetoothPowerStateChange = { [weak self] powerOn, source in
            DispatchQueue.main.async {
                self?.handleBluetoothPowerStateChange(powerOn, source: source)
            }
        }
        monitor.onWiFiPowerStateChange = { [weak self] powerOn, source in
            DispatchQueue.main.async {
                self?.handleWiFiPowerStateChange(powerOn, source: source)
            }
        }
        monitor.onWiFiMonitoringError = { errorMessage in
            AppLog.wifi.error("Failed to monitor Wi-Fi power changes. error=\(errorMessage, privacy: .public)")
        }
        wirelessStateMonitor = monitor
        monitor.start()
    }

    private func handleBluetoothPowerStateChange(_ powerOn: Bool?, source: String) {
        guard let powerOn else {
            AppLog.bluetooth.warning("Bluetooth power state update was unknown; keeping previous cache. source=\(source, privacy: .public), cachedPowerOn=\(self.stateDescription(self.cachedBluetoothWasOn), privacy: .public)")
            return
        }

        cachedBluetoothWasOn = powerOn
        AppLog.bluetooth.notice("Bluetooth power state cache updated. source=\(source, privacy: .public), powerOn=\(powerOn, privacy: .public)")
    }

    private func handleWiFiPowerStateChange(_ powerOn: Bool?, source: String) {
        guard let powerOn else {
            AppLog.wifi.warning("Wi-Fi power state update was unknown; keeping previous cache. source=\(source, privacy: .public), cachedPowerOn=\(self.stateDescription(self.cachedWiFiWasOn), privacy: .public)")
            return
        }

        cachedWiFiWasOn = powerOn
        AppLog.wifi.notice("Wi-Fi power state cache updated. source=\(source, privacy: .public), powerOn=\(powerOn, privacy: .public)")
    }

    private func storePreSleepWirelessState(_ decision: WirelessSleepDecision) {
        if let bluetoothWasOn = decision.bluetoothWasOn {
            UserDefaults.standard.set(bluetoothWasOn, forKey: bluetoothWasOnBeforeSleepKey)
        } else {
            UserDefaults.standard.removeObject(forKey: bluetoothWasOnBeforeSleepKey)
        }

        if let wifiWasOn = decision.wifiWasOn {
            UserDefaults.standard.set(wifiWasOn, forKey: wifiWasOnBeforeSleepKey)
        } else {
            UserDefaults.standard.removeObject(forKey: wifiWasOnBeforeSleepKey)
        }

        AppLog.power.notice("Stored cached pre-sleep wireless state. bluetoothWasOn=\(self.stateDescription(decision.bluetoothWasOn), privacy: .public), wifiWasOn=\(self.stateDescription(decision.wifiWasOn), privacy: .public)")
    }

    private func storedBool(forKey key: String) -> Bool? {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return nil
        }

        return UserDefaults.standard.bool(forKey: key)
    }

    private func logSkippedBluetoothSleepAction(state: Bool?) {
        if state == nil {
            AppLog.bluetooth.notice("Skipping Bluetooth off request because pre-sleep Bluetooth state is unknown.")
        } else {
            AppLog.bluetooth.notice("Skipping Bluetooth off request because Bluetooth was off before sleep.")
        }
    }

    private func logSkippedWiFiSleepAction(state: Bool?) {
        if state == nil {
            AppLog.wifi.notice("Skipping Wi-Fi off request because pre-sleep Wi-Fi state is unknown.")
        } else {
            AppLog.wifi.notice("Skipping Wi-Fi off request because Wi-Fi was off before sleep.")
        }
    }

    private func stateDescription(_ value: Bool?) -> String {
        guard let value else {
            return "unknown"
        }

        return value ? "true" : "false"
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

    // MARK: Log viewer

    private func showLogsWindow() {
        if logsWindow == nil {
            logsWindow = makeLogsWindow()
        }

        logsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshLogsWindow()
    }

    private func makeLogsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("XSnooze Logs", comment: "Log viewer window title")
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 720, height: 420))
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView

        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 58, width: 688, height: 346))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.autoresizingMask = [.width, .height]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = NSLocalizedString("Loading logs...", comment: "Log viewer loading placeholder")
        scrollView.documentView = textView
        contentView.addSubview(scrollView)

        let refreshButton = NSButton(
            title: NSLocalizedString("Refresh", comment: "Refresh logs button"),
            target: self,
            action: #selector(refreshLogsClicked(_:))
        )
        refreshButton.frame = NSRect(x: 16, y: 16, width: 96, height: 28)
        refreshButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(refreshButton)

        let copyButton = NSButton(
            title: NSLocalizedString("Copy", comment: "Copy logs button"),
            target: self,
            action: #selector(copyLogsClicked(_:))
        )
        copyButton.frame = NSRect(x: 124, y: 16, width: 96, height: 28)
        copyButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(copyButton)

        let closeButton = NSButton(
            title: NSLocalizedString("Close", comment: "Close logs window button"),
            target: self,
            action: #selector(closeLogsClicked(_:))
        )
        closeButton.frame = NSRect(x: 608, y: 16, width: 96, height: 28)
        closeButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(closeButton)

        logsTextView = textView
        logsRefreshButton = refreshButton
        logsCopyButton = copyButton
        return window
    }

    private func refreshLogsWindow() {
        logsTextView?.string = NSLocalizedString("Loading logs...", comment: "Log viewer loading placeholder")
        logsRefreshButton?.isEnabled = false
        logsCopyButton?.isEnabled = false

        DispatchQueue.global(qos: .utility).async {
            let result = self.loadRecentLogs()
            DispatchQueue.main.async { [weak self] in
                self?.logsTextView?.string = result
                self?.logsRefreshButton?.isEnabled = true
                self?.logsCopyButton?.isEnabled = true
            }
        }
    }

    private func loadRecentLogs() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: XSnoozeLogQuery.executablePath)
        process.arguments = XSnoozeLogQuery.arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return String(
                format: NSLocalizedString("Failed to load logs: %@", comment: "Log viewer process launch failure"),
                error.localizedDescription
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errorOutput.isEmpty ? output : errorOutput
            return String(
                format: NSLocalizedString("Failed to load logs: %@", comment: "Log viewer command failure"),
                message.isEmpty ? "log show exited with status \(process.terminationStatus)" : message
            )
        }

        return output.isEmpty
            ? NSLocalizedString("No XSnooze notice logs found in the last 24 hours.", comment: "Log viewer empty state")
            : output
    }

    // MARK: UI state

    private func initStatusItem() {
        if let icon = NSImage(named: "bluesnooze") {
            icon.size = NSSize(width: 18, height: 18)
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
        launchAtLoginCheckmark?.isHidden = state != .on
    }

    private func setToggleIconState() {
        let hideIcon = UserDefaults.standard.bool(forKey: "hideIcon")
        let state = hideIcon ? NSControl.StateValue.on : NSControl.StateValue.off
        toggleIconMenuItem.state = state
        toggleIconCheckmark?.isHidden = state != .on
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
        NSApp.activate(ignoringOtherApps: true)
        statusPopover.contentViewController?.view.window?.makeKey()
        startPopoverEventMonitoring()
    }

    func popoverDidClose(_ notification: Notification) {
        statusPopoverClosedAt = Date()
        stopPopoverEventMonitoring()
        scheduleHideIconIfNeeded()
    }

    private func closeStatusPopoverIfNeeded() {
        guard statusPopover.isShown else {
            return
        }

        statusPopover.performClose(nil)
    }

    private func startPopoverEventMonitoring() {
        stopPopoverEventMonitoring()
        popoverEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else {
                return event
            }

            if event.type == .keyDown, event.keyCode == 53 {
                self.closeStatusPopoverIfNeeded()
                return nil
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
                let popoverWindow = self.statusPopover.contentViewController?.view.window
                if event.window !== popoverWindow {
                    self.closeStatusPopoverIfNeeded()
                }
            }

            return event
        }
        popoverGlobalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeStatusPopoverIfNeeded()
            }
        }
    }

    private func stopPopoverEventMonitoring() {
        if let popoverEventMonitor {
            NSEvent.removeMonitor(popoverEventMonitor)
            self.popoverEventMonitor = nil
        }

        if let popoverGlobalEventMonitor {
            NSEvent.removeMonitor(popoverGlobalEventMonitor)
            self.popoverGlobalEventMonitor = nil
        }
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 260))

        let launchRow = makeMenuToggleRow(
            title: NSLocalizedString("Launch at login", comment: "Launch at login menu item"),
            action: #selector(launchAtLoginClicked(_:))
        )
        launchRow.checkmark.frame.origin = NSPoint(x: 12, y: 106)
        launchRow.titleLabel.frame = NSRect(x: 26, y: 104, width: 260, height: 18)
        launchRow.control.frame = NSRect(x: 8, y: 102, width: 284, height: 22)
        view.addSubview(launchRow.control)
        view.addSubview(launchRow.checkmark)
        view.addSubview(launchRow.titleLabel)

        let toggleIconRow = makeMenuToggleRow(
            title: NSLocalizedString("Hide menu bar icon", comment: "Hide menu bar icon menu item"),
            action: #selector(toggleIconClicked(_:))
        )
        toggleIconRow.checkmark.frame.origin = NSPoint(x: 12, y: 78)
        toggleIconRow.titleLabel.frame = NSRect(x: 26, y: 76, width: 260, height: 18)
        toggleIconRow.control.frame = NSRect(x: 8, y: 74, width: 284, height: 22)
        view.addSubview(toggleIconRow.control)
        view.addSubview(toggleIconRow.checkmark)
        view.addSubview(toggleIconRow.titleLabel)

        let lowBatteryReminderRow = makeMenuToggleRow(
            title: NSLocalizedString("Low Battery Reminder", comment: "Low battery reminder menu item"),
            action: #selector(lowBatteryReminderClicked(_:))
        )
        lowBatteryReminderRow.checkmark.frame.origin = NSPoint(x: 12, y: 232)
        lowBatteryReminderRow.titleLabel.frame = NSRect(x: 26, y: 230, width: 260, height: 18)
        lowBatteryReminderRow.control.frame = NSRect(x: 8, y: 228, width: 284, height: 22)
        view.addSubview(lowBatteryReminderRow.control)
        view.addSubview(lowBatteryReminderRow.checkmark)
        view.addSubview(lowBatteryReminderRow.titleLabel)

        let thresholdLabel = makeLowBatteryLabel()
        thresholdLabel.frame = NSRect(x: 44, y: 198, width: 140, height: 18)
        view.addSubview(thresholdLabel)

        let thresholdStepper = makeLowBatteryStepper(
            valueWidth: 44,
            decrementAction: #selector(lowBatteryThresholdDecrementClicked(_:)),
            incrementAction: #selector(lowBatteryThresholdIncrementClicked(_:))
        )
        thresholdStepper.decrementButton.frame.origin = NSPoint(x: 184, y: 195)
        thresholdStepper.valueLabel.frame.origin = NSPoint(x: 212, y: 198)
        thresholdStepper.incrementButton.frame.origin = NSPoint(x: 260, y: 195)
        view.addSubview(thresholdStepper.decrementButton)
        view.addSubview(thresholdStepper.valueLabel)
        view.addSubview(thresholdStepper.incrementButton)

        let forceHibernateRow = makeMenuToggleRow(
            title: NSLocalizedString("Hibernate if no response", comment: "Low battery force hibernation checkbox"),
            action: #selector(lowBatteryForceHibernateClicked(_:))
        )
        forceHibernateRow.checkmark.frame.origin = NSPoint(x: 30, y: 174)
        forceHibernateRow.titleLabel.frame = NSRect(x: 44, y: 172, width: 242, height: 18)
        forceHibernateRow.control.frame = NSRect(x: 26, y: 170, width: 266, height: 22)
        view.addSubview(forceHibernateRow.control)
        view.addSubview(forceHibernateRow.checkmark)
        view.addSubview(forceHibernateRow.titleLabel)

        let countdownLabel = makeLowBatteryLabel()
        countdownLabel.frame = NSRect(x: 44, y: 142, width: 140, height: 18)
        view.addSubview(countdownLabel)

        let countdownStepper = makeLowBatteryStepper(
            valueWidth: 44,
            decrementAction: #selector(lowBatteryCountdownDecrementClicked(_:)),
            incrementAction: #selector(lowBatteryCountdownIncrementClicked(_:))
        )
        countdownStepper.decrementButton.frame.origin = NSPoint(x: 184, y: 139)
        countdownStepper.valueLabel.frame.origin = NSPoint(x: 212, y: 142)
        countdownStepper.incrementButton.frame.origin = NSPoint(x: 260, y: 139)
        view.addSubview(countdownStepper.decrementButton)
        view.addSubview(countdownStepper.valueLabel)
        view.addSubview(countdownStepper.incrementButton)

        view.addSubview(makeSeparator(frame: NSRect(x: 0, y: 130, width: 300, height: 1)))

        let logsRow = makeMenuCommandRow(
            title: NSLocalizedString("View Logs", comment: "Open log viewer menu item"),
            action: #selector(showLogsClicked(_:))
        )
        logsRow.titleLabel.frame = NSRect(x: 26, y: 48, width: 160, height: 18)
        logsRow.control.frame = NSRect(x: 8, y: 46, width: 284, height: 22)
        view.addSubview(logsRow.control)
        view.addSubview(logsRow.titleLabel)

        view.addSubview(makeSeparator(frame: NSRect(x: 0, y: 38, width: 300, height: 1)))

        let quitRow = makeMenuCommandRow(
            title: NSLocalizedString("Quit", comment: "Quit menu item"),
            action: #selector(quitClicked(_:))
        )
        quitRow.titleLabel.frame = NSRect(x: 26, y: 12, width: 72, height: 18)
        quitRow.control.frame = NSRect(x: 8, y: 10, width: 284, height: 22)
        view.addSubview(quitRow.control)
        view.addSubview(quitRow.titleLabel)

        let versionLabel = NSTextField(labelWithString: appVersionText())
        versionLabel.alignment = .right
        versionLabel.font = .menuFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 198, y: 12, width: 76, height: 18)
        view.addSubview(versionLabel)

        self.launchAtLoginButton = launchRow.control
        self.toggleIconButton = toggleIconRow.control
        self.lowBatteryReminderButton = lowBatteryReminderRow.control
        launchAtLoginCheckmark = launchRow.checkmark
        toggleIconCheckmark = toggleIconRow.checkmark
        lowBatteryReminderCheckmark = lowBatteryReminderRow.checkmark
        lowBatteryForceHibernateCheckmark = forceHibernateRow.checkmark
        lowBatteryForceHibernateTitleLabel = forceHibernateRow.titleLabel
        self.versionLabel = versionLabel
        lowBatteryThresholdLabel = thresholdLabel
        lowBatteryThresholdValueLabel = thresholdStepper.valueLabel
        lowBatteryThresholdDecrementButton = thresholdStepper.decrementButton
        lowBatteryThresholdIncrementButton = thresholdStepper.incrementButton
        lowBatteryForceHibernateCheckbox = forceHibernateRow.control
        lowBatteryCountdownLabel = countdownLabel
        lowBatteryCountdownValueLabel = countdownStepper.valueLabel
        lowBatteryCountdownDecrementButton = countdownStepper.decrementButton
        lowBatteryCountdownIncrementButton = countdownStepper.incrementButton

        return view
    }

    private func makeMenuToggleRow(title: String, action: Selector) -> (checkmark: NSTextField, titleLabel: NSTextField, control: HoverMenuRowControl) {
        let checkmark = PassthroughTextField(labelWithString: "✓")
        checkmark.alignment = .right
        checkmark.font = .menuFont(ofSize: 13)
        checkmark.textColor = .labelColor
        checkmark.frame.size = NSSize(width: 14, height: 16)
        checkmark.isHidden = true

        let titleLabel = PassthroughTextField(labelWithString: title)
        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let control = HoverMenuRowControl(checkmarkLabel: checkmark, titleLabel: titleLabel, target: self, action: action)
        return (checkmark, titleLabel, control)
    }

    private func makeMenuCommandRow(title: String, action: Selector) -> (titleLabel: NSTextField, control: HoverMenuRowControl) {
        let titleLabel = PassthroughTextField(labelWithString: title)
        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let control = HoverMenuRowControl(checkmarkLabel: nil, titleLabel: titleLabel, target: self, action: action)
        return (titleLabel, control)
    }

    private func makeSeparator(frame: NSRect) -> NSBox {
        let separator = NSBox(frame: frame)
        separator.boxType = .separator
        return separator
    }

    private func appVersionText() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7.3"
        return version
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
        let button = HoverStepButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .menuFont(ofSize: 15)
        button.alignment = .center
        button.frame.size = NSSize(width: 24, height: 24)
        button.bezelStyle = .regularSquare
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
        lowBatteryReminderCheckmark?.isHidden = !lowBatterySettings.isEnabled
        lowBatteryThresholdLabel?.stringValue = NSLocalizedString("Battery alert threshold", comment: "Low battery threshold setting label")
        lowBatteryThresholdValueLabel?.stringValue = String(
            format: NSLocalizedString("%d%%", comment: "Low battery threshold value"),
            lowBatterySettings.thresholdPercentage
        )
        lowBatteryForceHibernateCheckmark?.isHidden = !lowBatterySettings.forceHibernateOnTimeout
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
        lowBatteryForceHibernateCheckmark?.alphaValue = lowBatterySettings.isEnabled ? 1.0 : disabledLowBatteryControlAlpha
        lowBatteryForceHibernateTitleLabel?.isEnabled = lowBatterySettings.isEnabled
        lowBatteryForceHibernateTitleLabel?.alphaValue = 1.0
        lowBatteryForceHibernateTitleLabel?.textColor = lowBatterySettings.isEnabled ? .labelColor : .disabledControlTextColor

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
    
}

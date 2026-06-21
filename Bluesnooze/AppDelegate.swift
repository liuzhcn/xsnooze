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

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var launchAtLoginMenuItem: NSMenuItem!
    @IBOutlet weak var toggleIconMenuItem: NSMenuItem!

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hideIconTask: DispatchWorkItem?
    private let bluetoothWasOnBeforeSleepKey = "bluetoothWasOnBeforeSleep"
    private let wifiWasOnBeforeSleepKey = "wifiWasOnBeforeSleep"

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        initStatusItem()
        setLaunchAtLoginState()
        setToggleIconState()
        setupNotificationHandlers()
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
        let bluetoothWasOn = isBluetoothOn()
        let wifiWasOn = isWiFiOn()
        UserDefaults.standard.set(bluetoothWasOn, forKey: bluetoothWasOnBeforeSleepKey)
        UserDefaults.standard.set(wifiWasOn, forKey: wifiWasOnBeforeSleepKey)

        if bluetoothWasOn {
            if hasBluetoothPermission() {
                setBluetooth(powerOn: false)
            }
        }

        if wifiWasOn {
            setWiFi(powerOn: false)
        }
    }

    @objc func onPowerUp(note: NSNotification) {
        let bluetoothWasOn = UserDefaults.standard.bool(forKey: bluetoothWasOnBeforeSleepKey)
        let wifiWasOn = UserDefaults.standard.bool(forKey: wifiWasOnBeforeSleepKey)

        if bluetoothWasOn && hasBluetoothPermission() {
            setBluetooth(powerOn: true)
        }

        if wifiWasOn {
            setWiFi(powerOn: true)
        }

        clearStoredPowerStates()
    }

    private func setBluetooth(powerOn: Bool) {
        IOBluetoothPreferenceSetControllerPowerState(powerOn ? 1 : 0)
    }

    private func isBluetoothOn() -> Bool {
        guard hasBluetoothPermission(),
              let bluetoothController = IOBluetoothHostController.default() else {
            return false
        }

        return bluetoothController.powerState == kBluetoothHCIPowerStateON
    }

    private func setWiFi(powerOn: Bool) {
        guard let interface = CWWiFiClient.shared().interface() else {
            NSLog("XSnooze: No Wi-Fi interface found")
            return
        }

        do {
            try interface.setPower(powerOn)
        } catch {
            NSLog("XSnooze: Failed to set Wi-Fi power state to \(powerOn): \(error)")
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

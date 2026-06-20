//
//  AppDelegate.swift
//  Bluesnooze
//
//  Created by Oliver Peate on 07/04/2020.
//  Copyright © 2020 Oliver Peate. All rights reserved.
//

import Cocoa
import IOBluetooth
import LaunchAtLogin

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

    @IBOutlet weak var statusMenu: NSMenu!
    @IBOutlet weak var launchAtLoginMenuItem: NSMenuItem!
    @IBOutlet weak var toggleIconMenuItem: NSMenuItem!

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hideIconTask: DispatchWorkItem?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        initStatusItem()
        setLaunchAtLoginState()
        setToggleIconState()
        setupNotificationHandlers()
        
        // 检查蓝牙权限，只有在有权限时才设置蓝牙状态
        checkBluetoothPermissionAndSetState()
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
            NSWorkspace.willPowerOffNotification: #selector(onPowerDown(note:)),
            NSWorkspace.didWakeNotification: #selector(onPowerUp(note:))
        ].forEach { notification, sel in
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: sel, name: notification, object: nil)
        }
    }

    @objc func onPowerDown(note: NSNotification) {
        if hasBluetoothPermission() {
            // 只有在使用电池时才关闭蓝牙，插电时不关闭
            if isRunningOnBattery() {
                setBluetooth(powerOn: false)
            }
        }
    }

    @objc func onPowerUp(note: NSNotification) {
        if hasBluetoothPermission() {
            setBluetooth(powerOn: true)
        }
    }

    private func setBluetooth(powerOn: Bool) {
        IOBluetoothPreferenceSetControllerPowerState(powerOn ? 1 : 0)
    }

    // MARK: UI state

    private func initStatusItem() {
        // 始终先显示图标，以便用户可以访问菜单
        if let icon = NSImage(named: "bluesnooze") {
            icon.isTemplate = true
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "Bluesnooze"
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
        toggleIconMenuItem.title = "Hide menu bar icon"
    }
    
    // MARK: Bluetooth permission handling
    
    private func checkBluetoothPermissionAndSetState() {
        if hasBluetoothPermission() {
            setBluetooth(powerOn: true)
        }
    }
    
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
    
    // MARK: Power source detection
    
    private func isRunningOnBattery() -> Bool {
        // 使用shell命令检查电源状态
        let task = Process()
        task.launchPath = "/usr/bin/pmset"
        task.arguments = ["-g", "ps"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            // 如果输出包含 "AC Power"，说明插着电源
            return !output.contains("AC Power")
        }
        
        // 如果无法获取电源信息，默认认为是使用电池（更安全的选择）
        return true
    }
}

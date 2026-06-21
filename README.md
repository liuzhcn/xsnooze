![XSnooze logo](images/icon.png)

# XSnooze

XSnooze prevents your sleeping Mac from connecting to Bluetooth accessories and
Wi-Fi while it is asleep.

XSnooze is a maintained fork of the original Bluesnooze project. The upstream
project has not been updated recently, so this fork focuses on fixing practical
issues on newer versions of macOS and adding more complete control over
sleep-related wireless behavior.
It can also warn you when battery power is low and hibernate the Mac if nobody
responds.

[Download the latest fork release][download-latest].

Please note the latest release requires macOS Monterey (12.0) or higher.

## What's Different in This Fork

- Better compatibility with newer macOS privacy and Bluetooth behavior.
- Bluetooth permission usage description for modern macOS.
- Bluetooth and Wi-Fi are turned off during sleep if they were on before sleep.
- Bluetooth and Wi-Fi are restored after wake only if they were on before sleep.
- Low-battery protection warns below 30% on battery power and can hibernate the
  Mac after a 60-second countdown if there is no response.
- Menu bar icon visibility can be controlled from the app menu.
- English and Simplified Chinese localization.
- Updated dependencies for current build environments.

## About

If you pair Bluetooth headphones or speakers with both your phone and Mac, it
can be frustrating when your sleeping Mac connects intermittently and disrupts
the audio.

With XSnooze, Bluetooth and Wi-Fi are switched off when your Mac sleeps under
configured conditions, then restored when your Mac wakes if they were previously
on.

When the Mac is running on battery and drops below 30%, XSnooze shows a
countdown reminder. If nobody confirms the reminder within 60 seconds, XSnooze
temporarily switches Battery Power sleep mode to `hibernatemode 25`, puts the
Mac to sleep, and restores the previous sleep mode after the next wake or app
launch.

![Screenshot showing XSnooze in the status bar](images/screenshot.png)

## Installation

1. Download `XSnooze.zip` from the [latest release][download-latest].
2. In Finder, open `XSnooze.zip` in your `Downloads` directory.
3. Drag `XSnooze.app` to your `Applications` directory.
4. Optional: configure `Launch at login` from the menu bar app.

For local builds, run `install-helper.command` once if you want forced
low-battery hibernation. It installs the XSnooze helper as a root LaunchDaemon
so the app can run the required `pmset` operations without asking for a password
during a low-battery event. Run `uninstall-helper.command` to remove it.

## Caveats

- This app is not compatible with the "Allow your Apple Watch to unlock your
  Mac" feature.
- This app uses a private API to switch Bluetooth on and off. That is why it is
  not suitable for App Store distribution.
- Forced low-battery hibernation requires a correctly signed release build so
  macOS can authorize the privileged helper.

## FAQs

### Is this the original Bluesnooze project?

No. This is a maintained fork based on the original project by Oliver Peate.
The original repository is available at
[odlp/bluesnooze](https://github.com/odlp/bluesnooze).

### How can I hide or restore the XSnooze icon?

Use the menu bar item:

1. Open the XSnooze menu.
2. Toggle `Hide menu bar icon`.

When hiding is enabled, the icon is shown temporarily when the app is opened
again so that you can change the setting.

---

# XSnooze 中文说明

XSnooze 可以避免休眠中的 Mac 自动连接蓝牙耳机、音箱等蓝牙设备，并在休眠期
间关闭 Wi-Fi。

XSnooze 是基于原 Bluesnooze 项目继续维护的 fork。由于上游项目近期没有继续
更新，本 fork 主要用于解决新版 macOS 使用中的实际问题，并提供更完整的睡眠
相关无线设置能力。
它还可以在电量不足时提醒用户，并在无人响应时让 Mac 进入深度休眠。

[下载当前 fork 的最新版本][download-latest]。

当前版本需要 macOS Monterey (12.0) 或更高版本。

## 本 fork 的主要变化

- 更好适配新版 macOS 的隐私权限和蓝牙行为。
- 增加新版 macOS 所需的蓝牙权限说明。
- Mac 睡眠前自动关闭原本处于开启状态的蓝牙和 Wi-Fi。
- Mac 唤醒后只恢复睡眠前处于开启状态的蓝牙和 Wi-Fi。
- 电池供电且电量低于 30% 时弹出提醒；如果 60 秒内无人确认，可以让 Mac 进
  入深度休眠。
- 可以在菜单中控制是否隐藏菜单栏图标。
- 支持英文和简体中文界面。
- 更新依赖，以适配当前构建环境。

## 使用场景

如果你的蓝牙耳机或音箱同时配对了手机和 Mac，休眠中的 Mac 可能会偶尔抢占
蓝牙连接，打断手机上的音频播放。

XSnooze 会在 Mac 进入睡眠时按配置关闭蓝牙和 Wi-Fi，并在 Mac 唤醒后恢复睡眠
前处于开启状态的无线连接。

当 Mac 使用电池且电量低于 30% 时，XSnooze 会显示倒计时提醒。如果 60 秒内
无人确认，XSnooze 会临时把电池供电下的睡眠模式切换为 `hibernatemode 25`，
让 Mac 立即睡眠，并在下次唤醒或 App 启动后恢复原来的睡眠模式。

## 安装

1. 从 [latest release][download-latest] 下载 `XSnooze.zip`。
2. 在 Finder 中打开下载目录里的 `XSnooze.zip`。
3. 将 `XSnooze.app` 拖到 `Applications` 目录。
4. 可选：在菜单栏中启用 `登录时启动`。

如果使用本机构建版本，并希望启用低电量强制休眠，请先运行一次
`install-helper.command`。它会把 XSnooze Helper 安装为 root LaunchDaemon，
这样低电量时就可以自动执行所需的 `pmset` 操作，不会临时要求输入管理员密
码。运行 `uninstall-helper.command` 可以移除 Helper。

## 注意事项

- 本应用不兼容“允许 Apple Watch 解锁 Mac”功能。
- 本应用使用私有 API 来开关蓝牙，因此不适合通过 App Store 分发。
- 低电量强制休眠需要使用正确签名的发布版本，macOS 才能授权特权 Helper。

## 常见问题

### 这是原版 Bluesnooze 项目吗？

不是。这是基于 Oliver Peate 原项目继续维护的 fork。原项目地址是
[odlp/bluesnooze](https://github.com/odlp/bluesnooze)。

### 如何隐藏或恢复 XSnooze 图标？

通过菜单栏中的 XSnooze 菜单操作：

1. 打开 XSnooze 菜单。
2. 勾选或取消 `隐藏菜单栏图标`。

启用隐藏后，再次打开应用时图标会临时显示，方便你重新修改设置。

[download-latest]: https://github.com/liuzhcn/xsnooze/releases/latest

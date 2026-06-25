# Repository Guidelines

## Project Structure & Module Organization

This is a macOS Swift/Xcode project for XSnooze, a maintained fork of Bluesnooze. Main app code lives in `Bluesnooze/`, including `AppDelegate.swift`, battery and power monitoring logic, XIB UI resources, entitlements, localized strings, and asset catalogs. Privileged helper code lives in `XSnoozeHelper/`, with shared XPC protocol types in `Shared/`. Standalone checks are in `Tests/`, currently focused on low-battery policy behavior. Installer utilities for the helper live in `Scripts/`.

## Build, Test, and Development Commands

- `xcodebuild -list -project Bluesnooze.xcodeproj`: list available targets and schemes.
- `xcodebuild -project Bluesnooze.xcodeproj -scheme Bluesnooze -configuration Debug build`: build the menu bar app locally.
- `xcodebuild -project Bluesnooze.xcodeproj -scheme XSnoozeHelper -configuration Debug build`: build the privileged helper.
- `swiftc Bluesnooze/LowBatteryPolicy.swift Tests/LowBatteryPolicyTests.swift -o /tmp/LowBatteryPolicyTests && /tmp/LowBatteryPolicyTests`: compile and run the standalone policy tests.
- `Scripts/install-helper.command` and `Scripts/uninstall-helper.command`: install or remove the privileged helper for local testing of forced hibernation.

## Coding Style & Naming Conventions

Use Swift defaults: 4-space indentation, `UpperCamelCase` for types, and `lowerCamelCase` for functions, properties, and local variables. Keep small domain types near their feature area, as with `LowBatteryPolicy` and `PowerSourceSnapshot`. Prefer explicit, readable control flow over clever compact expressions, especially around power, Bluetooth, Wi-Fi, and privileged-helper behavior. Keep localized user-facing strings in the appropriate `.lproj` files rather than hard-coding new UI text.

## Testing Guidelines

Tests currently use a lightweight Swift executable with custom assertions, not XCTest. Add focused tests under `Tests/` using `*Tests.swift` naming. When changing battery warning thresholds, bucket logic, sleep behavior, or helper protocol decisions, add or update tests that cover boundary values and negative cases. Run the standalone `swiftc` test command before submitting changes.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects, for example `Add low battery hibernation helper`, `Update Bluetooth sleep behavior`, and `Fix warnings about build-phase scripts`. Follow that style and keep subjects specific to one change. Pull requests should include a concise summary, test commands run, affected macOS behavior, and screenshots or recordings when UI/menu behavior changes. Note any signing, helper installation, or permission requirements needed to reproduce the change.

## Security & Configuration Tips

This app uses private Bluetooth APIs and a privileged helper for selected `pmset` operations, so avoid broadening privileges casually. Do not commit signing identities, certificates, provisioning artifacts, or machine-specific build settings. Treat helper plist, entitlement, and XPC protocol changes as security-sensitive and explain their impact in the PR.

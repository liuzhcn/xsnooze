# Repository Guidelines

## Project Structure & Module Organization

This is XSnooze, a macOS Swift/Xcode Bluesnooze fork. Main app code lives in `Bluesnooze/`, including `AppDelegate.swift`, power monitoring, XIB UI, entitlements, localized strings, and assets. Privileged helper code is in `XSnoozeHelper/`, with shared XPC protocol types in `Shared/`. Standalone checks are in `Tests/`, utilities in `Scripts/`, README images in `images/`, and release artifacts under `dist/`. The historical app target remains `Bluesnooze`.

## Build, Test, and Development Commands

- `carthage bootstrap --platform macOS`: installs the pinned `LaunchAtLogin` dependency from `Cartfile.resolved`.
- `open Bluesnooze.xcodeproj`: opens the project in Xcode for development and signing.
- `xcodebuild -list -project Bluesnooze.xcodeproj`: lists targets and schemes.
- `xcodebuild -project Bluesnooze.xcodeproj -scheme Bluesnooze -configuration Debug build`: build the menu bar app.
- `xcodebuild -project Bluesnooze.xcodeproj -scheme XSnoozeHelper -configuration Debug build`: build the privileged helper.
- `swiftc Bluesnooze/LowBatteryPolicy.swift Tests/LowBatteryPolicyTests.swift -o /tmp/LowBatteryPolicyTests && /tmp/LowBatteryPolicyTests`: runs standalone policy tests.
- `swiftlint`: runs linting rules; `.swiftlint.yml` currently excludes `Carthage/`.
- `Scripts/install-helper.command` and `Scripts/uninstall-helper.command`: install or remove the helper locally.

## Coding Style & Naming Conventions

Use Swift defaults: 4-space indentation, `UpperCamelCase` for types, and `lowerCamelCase` for functions, properties, and locals. Keep small domain types near their feature area, as with `LowBatteryPolicy` and `PowerSourceSnapshot`. Prefer explicit control flow around power, Bluetooth, Wi-Fi, and helper behavior. Keep UI text in `.lproj` files.

## Testing Guidelines

Tests use a lightweight Swift executable with custom assertions, not XCTest. Add focused tests under `Tests/` using `*Tests.swift` naming. For battery thresholds, bucket logic, sleep behavior, or helper protocol decisions, cover boundary values and negative cases. Run the `swiftc` test command, and manually validate on macOS Monterey 12.0 or newer when sleep, wake, Bluetooth, Wi-Fi, or login-item behavior changes.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects, for example `Add low battery hibernation helper`, `Update Bluetooth sleep behavior`, and `Fix warnings about build-phase scripts`. Keep subjects focused on one change. Pull requests should include a concise summary, test commands, affected macOS behavior, and screenshots or recordings for UI/menu changes. Note signing, helper installation, or permission requirements.

## Security & Configuration Tips

This app uses private Bluetooth APIs and a privileged helper for selected `pmset` operations, so avoid broadening privileges casually. Do not commit signing identities, certificates, provisioning artifacts, personal team IDs, machine-specific settings, derived data, or built `.app` bundles. Keep dependency updates pinned in `Cartfile.resolved`. Treat helper plist, entitlement, and XPC changes as security-sensitive.

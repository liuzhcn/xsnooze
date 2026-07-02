import Foundation

enum PowerEventType: Equatable {
    case sleep
    case wake
}

enum PowerEventSource: String, Equatable {
    case iokit = "IOKit"
    case nsWorkspace = "NSWorkspace"
}

struct SleepPowerEventDecision: Equatable {
    let shouldHandleWirelessSleep: Bool
    let isDiagnosticOnly: Bool
    let isDuplicate: Bool
    let iokitNotificationsAvailable: Bool
    let iokitSleepObserved: Bool
    let handlerSource: String
}

struct WakePowerEventDecision: Equatable {
    let shouldRestoreWireless: Bool
    let isDiagnosticOnly: Bool
    let isDuplicate: Bool
    let handlerSource: String
}

struct PowerEventDeduplicator {
    private let duplicateWindow: TimeInterval
    private var lastHandledEvent: PowerEventType?
    private var lastHandledAt: Date?

    init(duplicateWindow: TimeInterval) {
        self.duplicateWindow = duplicateWindow
    }

    mutating func shouldHandle(_ event: PowerEventType, at date: Date = Date()) -> Bool {
        if lastHandledEvent == event,
           let lastHandledAt,
           date.timeIntervalSince(lastHandledAt) < duplicateWindow {
            return false
        }

        lastHandledEvent = event
        lastHandledAt = date
        return true
    }
}

struct PowerEventRouter {
    private var deduplicator: PowerEventDeduplicator
    private(set) var iokitNotificationsAvailable: Bool
    private(set) var iokitSleepObserved = false

    init(duplicateWindow: TimeInterval, iokitNotificationsAvailable: Bool) {
        self.deduplicator = PowerEventDeduplicator(duplicateWindow: duplicateWindow)
        self.iokitNotificationsAvailable = iokitNotificationsAvailable
    }

    mutating func setIOKitNotificationsAvailable(_ available: Bool) {
        iokitNotificationsAvailable = available
    }

    mutating func sleepDecision(source: PowerEventSource, at date: Date = Date()) -> SleepPowerEventDecision {
        switch source {
        case .iokit:
            iokitSleepObserved = true
            guard deduplicator.shouldHandle(.sleep, at: date) else {
                return SleepPowerEventDecision(
                    shouldHandleWirelessSleep: false,
                    isDiagnosticOnly: false,
                    isDuplicate: true,
                    iokitNotificationsAvailable: iokitNotificationsAvailable,
                    iokitSleepObserved: iokitSleepObserved,
                    handlerSource: source.rawValue
                )
            }

            return SleepPowerEventDecision(
                shouldHandleWirelessSleep: true,
                isDiagnosticOnly: false,
                isDuplicate: false,
                iokitNotificationsAvailable: iokitNotificationsAvailable,
                iokitSleepObserved: iokitSleepObserved,
                handlerSource: source.rawValue
            )

        case .nsWorkspace:
            if iokitNotificationsAvailable {
                return SleepPowerEventDecision(
                    shouldHandleWirelessSleep: false,
                    isDiagnosticOnly: true,
                    isDuplicate: false,
                    iokitNotificationsAvailable: iokitNotificationsAvailable,
                    iokitSleepObserved: iokitSleepObserved,
                    handlerSource: source.rawValue
                )
            }

            guard deduplicator.shouldHandle(.sleep, at: date) else {
                return SleepPowerEventDecision(
                    shouldHandleWirelessSleep: false,
                    isDiagnosticOnly: false,
                    isDuplicate: true,
                    iokitNotificationsAvailable: iokitNotificationsAvailable,
                    iokitSleepObserved: iokitSleepObserved,
                    handlerSource: "NSWorkspaceFallback"
                )
            }

            return SleepPowerEventDecision(
                shouldHandleWirelessSleep: true,
                isDiagnosticOnly: false,
                isDuplicate: false,
                iokitNotificationsAvailable: iokitNotificationsAvailable,
                iokitSleepObserved: iokitSleepObserved,
                handlerSource: "NSWorkspaceFallback"
            )
        }
    }

    mutating func wakeDecision(source: PowerEventSource, at date: Date = Date()) -> WakePowerEventDecision {
        iokitSleepObserved = false

        switch source {
        case .iokit:
            return WakePowerEventDecision(
                shouldRestoreWireless: false,
                isDiagnosticOnly: true,
                isDuplicate: false,
                handlerSource: source.rawValue
            )

        case .nsWorkspace:
            guard deduplicator.shouldHandle(.wake, at: date) else {
                return WakePowerEventDecision(
                    shouldRestoreWireless: false,
                    isDiagnosticOnly: false,
                    isDuplicate: true,
                    handlerSource: source.rawValue
                )
            }

            return WakePowerEventDecision(
                shouldRestoreWireless: true,
                isDiagnosticOnly: false,
                isDuplicate: false,
                handlerSource: source.rawValue
            )
        }
    }
}

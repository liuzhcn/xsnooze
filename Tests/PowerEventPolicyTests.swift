import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fatalError("\(message): expected \(expected), got \(actual)")
    }
}

func assertTrue(_ value: Bool, _ message: String) {
    if !value {
        fatalError(message)
    }
}

func assertFalse(_ value: Bool, _ message: String) {
    if value {
        fatalError(message)
    }
}

@main
struct PowerEventPolicyTests {
    static func main() {
        suppressesDuplicateSleepNotificationsInsideWindow()
        allowsDifferentEventTypesInsideWindow()
        allowsSameEventAfterWindow()
        iokitSleepHandlesAndWorkspaceSleepOnlyDiagnosesWhenIOKitAvailable()
        workspaceSleepFallsBackWhenIOKitIsUnavailable()
        iokitWakeOnlyLogsAndWorkspaceWakeRestores()
        wakeResetsIOKitSleepObservationForNextCycle()
        iokitMaintenanceSleepBeforeWorkspaceWakeDoesNotHandleWirelessAgain()
    }

    static func suppressesDuplicateSleepNotificationsInsideWindow() {
        var deduplicator = PowerEventDeduplicator(duplicateWindow: 5)
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        assertTrue(deduplicator.shouldHandle(.sleep, at: now), "First sleep event should be handled")
        assertFalse(
            deduplicator.shouldHandle(.sleep, at: now.addingTimeInterval(1)),
            "Duplicate sleep event inside the window should be suppressed"
        )
    }

    static func allowsDifferentEventTypesInsideWindow() {
        var deduplicator = PowerEventDeduplicator(duplicateWindow: 5)
        let now = Date(timeIntervalSinceReferenceDate: 2_000)

        assertTrue(deduplicator.shouldHandle(.sleep, at: now), "First sleep event should be handled")
        assertTrue(
            deduplicator.shouldHandle(.wake, at: now.addingTimeInterval(1)),
            "Wake event should not be suppressed by a recent sleep event"
        )
    }

    static func allowsSameEventAfterWindow() {
        var deduplicator = PowerEventDeduplicator(duplicateWindow: 5)
        let now = Date(timeIntervalSinceReferenceDate: 3_000)

        assertTrue(deduplicator.shouldHandle(.wake, at: now), "First wake event should be handled")
        assertTrue(
            deduplicator.shouldHandle(.wake, at: now.addingTimeInterval(6)),
            "Same event after the duplicate window should be handled"
        )
    }

    static func iokitSleepHandlesAndWorkspaceSleepOnlyDiagnosesWhenIOKitAvailable() {
        var router = PowerEventRouter(duplicateWindow: 5, iokitNotificationsAvailable: true)
        let now = Date(timeIntervalSinceReferenceDate: 4_000)

        let iokitDecision = router.sleepDecision(source: .iokit, at: now)
        assertTrue(iokitDecision.shouldHandleWirelessSleep, "IOKit sleep should handle wireless sleep")
        assertFalse(iokitDecision.isDiagnosticOnly, "IOKit sleep should not be diagnostic-only")
        assertTrue(iokitDecision.iokitSleepObserved, "IOKit sleep should mark IOKit sleep as observed")
        assertTrue(iokitDecision.iokitNotificationsAvailable, "IOKit should be marked available")
        assertEqual(iokitDecision.handlerSource, "IOKit", "IOKit sleep should use IOKit as the handler source")

        let workspaceDecision = router.sleepDecision(source: .nsWorkspace, at: now.addingTimeInterval(1))
        assertFalse(workspaceDecision.shouldHandleWirelessSleep, "Workspace sleep should not duplicate IOKit handling")
        assertTrue(workspaceDecision.isDiagnosticOnly, "Workspace sleep should be diagnostic-only when IOKit is available")
        assertTrue(workspaceDecision.iokitSleepObserved, "Workspace diagnostic should report whether IOKit sleep was observed")
        assertTrue(workspaceDecision.iokitNotificationsAvailable, "Workspace diagnostic should report IOKit availability")
        assertEqual(workspaceDecision.handlerSource, "NSWorkspace", "Workspace diagnostic should keep the original source")
    }

    static func workspaceSleepFallsBackWhenIOKitIsUnavailable() {
        var router = PowerEventRouter(duplicateWindow: 5, iokitNotificationsAvailable: false)
        let now = Date(timeIntervalSinceReferenceDate: 5_000)

        let decision = router.sleepDecision(source: .nsWorkspace, at: now)

        assertTrue(decision.shouldHandleWirelessSleep, "Workspace sleep should handle wireless sleep when IOKit is unavailable")
        assertFalse(decision.isDiagnosticOnly, "Workspace fallback should not be diagnostic-only")
        assertFalse(decision.iokitSleepObserved, "Workspace fallback should report that IOKit sleep was not observed")
        assertFalse(decision.iokitNotificationsAvailable, "Workspace fallback should report IOKit as unavailable")
        assertEqual(decision.handlerSource, "NSWorkspaceFallback", "Workspace fallback should use an explicit fallback source")
    }

    static func iokitWakeOnlyLogsAndWorkspaceWakeRestores() {
        var router = PowerEventRouter(duplicateWindow: 5, iokitNotificationsAvailable: true)
        let now = Date(timeIntervalSinceReferenceDate: 6_000)

        let iokitDecision = router.wakeDecision(source: .iokit, at: now)
        assertFalse(iokitDecision.shouldRestoreWireless, "IOKit wake should not restore wireless state")
        assertTrue(iokitDecision.isDiagnosticOnly, "IOKit wake should be diagnostic-only")
        assertEqual(iokitDecision.handlerSource, "IOKit", "IOKit wake should keep IOKit as the handler source")

        let workspaceDecision = router.wakeDecision(source: .nsWorkspace, at: now.addingTimeInterval(1))
        assertTrue(workspaceDecision.shouldRestoreWireless, "Workspace wake should restore wireless state")
        assertFalse(workspaceDecision.isDiagnosticOnly, "Workspace wake should not be diagnostic-only")
        assertEqual(workspaceDecision.handlerSource, "NSWorkspace", "Workspace wake should use NSWorkspace as the handler source")
    }

    static func wakeResetsIOKitSleepObservationForNextCycle() {
        var router = PowerEventRouter(duplicateWindow: 5, iokitNotificationsAvailable: true)
        let now = Date(timeIntervalSinceReferenceDate: 7_000)

        _ = router.sleepDecision(source: .iokit, at: now)
        _ = router.wakeDecision(source: .nsWorkspace, at: now.addingTimeInterval(10))

        let nextWorkspaceSleep = router.sleepDecision(source: .nsWorkspace, at: now.addingTimeInterval(20))

        assertTrue(nextWorkspaceSleep.isDiagnosticOnly, "Workspace sleep should still be diagnostic-only when IOKit is available")
        assertFalse(nextWorkspaceSleep.iokitSleepObserved, "Wake should reset IOKit sleep observation before the next cycle")
    }

    static func iokitMaintenanceSleepBeforeWorkspaceWakeDoesNotHandleWirelessAgain() {
        var router = PowerEventRouter(duplicateWindow: 5, iokitNotificationsAvailable: true)
        let now = Date(timeIntervalSinceReferenceDate: 8_000)

        let firstSleep = router.sleepDecision(source: .iokit, at: now)
        assertTrue(firstSleep.shouldHandleWirelessSleep, "First IOKit sleep should handle wireless state")

        let iokitWake = router.wakeDecision(source: .iokit, at: now.addingTimeInterval(100))
        assertTrue(iokitWake.isDiagnosticOnly, "IOKit wake should remain diagnostic-only")

        let maintenanceSleep = router.sleepDecision(source: .iokit, at: now.addingTimeInterval(101))
        assertFalse(
            maintenanceSleep.shouldHandleWirelessSleep,
            "Maintenance sleep before NSWorkspace wake should not overwrite pre-sleep wireless state"
        )
        assertTrue(maintenanceSleep.isDuplicate, "Maintenance sleep should be treated as part of the active sleep cycle")

        let workspaceWake = router.wakeDecision(source: .nsWorkspace, at: now.addingTimeInterval(130))
        assertTrue(workspaceWake.shouldRestoreWireless, "Workspace wake should end the active sleep cycle")

        let nextSleep = router.sleepDecision(source: .iokit, at: now.addingTimeInterval(140))
        assertTrue(nextSleep.shouldHandleWirelessSleep, "Next real sleep after workspace wake should handle wireless state")
    }
}

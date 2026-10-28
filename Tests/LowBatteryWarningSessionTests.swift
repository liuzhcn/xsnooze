import Foundation

@main
struct LowBatteryWarningSessionTests {
    static var failures = 0
    static let start = Date(timeIntervalSinceReferenceDate: 1_000)

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAIL: \(message)")
            failures += 1
        }
    }

    static func main() {
        requestBlocksPollsUntilWake()
        sleepDiscardsAnActiveCountdown()
        wakeStartsAFullCountdown()
        longSleepCannotExpireANewWarning()
        failureAllowsRetry()
        staleReplyCannotChangeANewRequest()
        cancellationAllowsAnotherWarning()
        if failures > 0 {
            exit(1)
        }
        print("LowBatteryWarningSessionTests passed")
    }

    static func requestBlocksPollsUntilWake() {
        var session = LowBatteryWarningSession()
        check(session.beginCountdown(seconds: 60, at: start), "Initial warning should start")
        session.endCountdown()
        guard let request = session.beginHibernateRequest() else {
            check(false, "First hibernation request should start")
            return
        }
        // Replay the 08:36:10 power poll while the asynchronous helper is running.
        check(!session.beginCountdown(seconds: 60, at: start.addingTimeInterval(60.005)), "Helper request must block an immediate duplicate warning")
        check(session.beginHibernateRequest() == nil, "A second helper request must be blocked")
        session.completeHibernateRequest(request, succeeded: true)
        check(!session.canStartWarning, "Helper success must stay blocked until wake")
        session.willSleep()
        check(!session.canStartWarning, "Power polls during sleep must not show a warning")
        session.didWake()
        check(session.canStartWarning, "Wake should permit a fresh warning")
    }

    static func sleepDiscardsAnActiveCountdown() {
        var session = LowBatteryWarningSession()
        _ = session.beginCountdown(seconds: 60, at: start)
        session.willSleep()
        check(session.deadline == nil, "Sleep must discard an active warning deadline")
        check(session.remainingSeconds(at: start.addingTimeInterval(120)) == nil, "A stale timer after sleep must not expire a warning")
        check(session.beginHibernateRequest() == nil, "A stale timeout during sleep must not request hibernation")
    }

    static func wakeStartsAFullCountdown() {
        var session = LowBatteryWarningSession()
        _ = session.beginCountdown(seconds: 60, at: start)
        session.willSleep()
        let wake = start.addingTimeInterval(55)
        session.didWake()
        check(session.beginCountdown(seconds: 60, at: wake), "Wake must replace the pre-sleep countdown")
        check(session.remainingSeconds(at: wake) == 60, "Wake must give the user all 60 seconds")
        check(session.remainingSeconds(at: start.addingTimeInterval(60)) == 55, "Old deadline must not cause hibernation five seconds after wake")
        check(session.remainingSeconds(at: wake.addingTimeInterval(60)) == 0, "New countdown should expire at its own deadline")
    }

    static func failureAllowsRetry() {
        var session = LowBatteryWarningSession()
        let request = session.beginHibernateRequest()!
        check(session.completeHibernateRequest(request, succeeded: false), "Current helper failure should be handled")
        check(session.beginCountdown(seconds: 60, at: start), "Helper failure must allow another complete countdown")
    }

    static func longSleepCannotExpireANewWarning() {
        var session = LowBatteryWarningSession()
        _ = session.beginCountdown(seconds: 60, at: start)
        session.willSleep()
        let wake = start.addingTimeInterval(8 * 60 * 60)
        session.didWake()
        check(session.remainingSeconds(at: wake) == nil, "An overnight sleep must not retain an expired deadline")
        check(session.beginCountdown(seconds: 300, at: wake), "Wake should accept the currently configured duration")
        check(session.remainingSeconds(at: wake.addingTimeInterval(1)) == 299, "An overnight sleep must not shorten the new countdown")
    }

    static func staleReplyCannotChangeANewRequest() {
        var session = LowBatteryWarningSession()
        let oldRequest = session.beginHibernateRequest()!
        session.willSleep()
        session.didWake()
        let newRequest = session.beginHibernateRequest()!
        check(!session.completeHibernateRequest(oldRequest, succeeded: false), "Old helper failure after wake must be ignored")
        check(!session.completeHibernateRequest(oldRequest, succeeded: true), "Old helper success after wake must be ignored")
        check(!session.canStartWarning, "Old reply must not unblock the new helper request")
        check(session.completeHibernateRequest(newRequest, succeeded: false), "New helper reply should still be handled")
        check(session.canStartWarning, "Current helper failure should unblock warnings")
    }

    static func cancellationAllowsAnotherWarning() {
        var session = LowBatteryWarningSession()
        _ = session.beginCountdown(seconds: 60, at: start)
        check(!session.beginCountdown(seconds: 60, at: start), "Active warning must not be duplicated")
        session.endCountdown()
        check(session.remainingSeconds(at: start) == nil, "Cancellation must remove the deadline")
        check(session.beginCountdown(seconds: 15, at: start), "Cancellation should allow a fresh warning")
        check(session.remainingSeconds(at: start) == 15, "New countdown should respect configured duration")
    }
}

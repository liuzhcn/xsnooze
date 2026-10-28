import Foundation

struct LowBatteryWarningSession {
    private(set) var deadline: Date?
    private var hibernateRequestID: UUID?
    private var isSleeping = false

    var canStartWarning: Bool {
        deadline == nil && hibernateRequestID == nil && !isSleeping
    }

    mutating func beginCountdown(seconds: Int, at now: Date = Date()) -> Bool {
        guard canStartWarning else {
            return false
        }
        deadline = now.addingTimeInterval(TimeInterval(seconds))
        return true
    }

    func remainingSeconds(at now: Date = Date()) -> Int? {
        deadline.map { max(0, Int(ceil($0.timeIntervalSince(now)))) }
    }

    mutating func endCountdown() {
        deadline = nil
    }

    mutating func beginHibernateRequest() -> UUID? {
        guard canStartWarning else {
            return nil
        }
        let id = UUID()
        hibernateRequestID = id
        return id
    }

    @discardableResult
    mutating func completeHibernateRequest(_ id: UUID, succeeded: Bool) -> Bool {
        guard hibernateRequestID == id else {
            return false
        }
        if !succeeded {
            hibernateRequestID = nil
        }
        // A successful sleepnow reply precedes actual sleep. Only wake re-arms
        // warnings, so a power poll cannot create a countdown in that gap.
        return true
    }

    mutating func willSleep() {
        isSleeping = true
        deadline = nil
    }

    mutating func didWake() {
        isSleeping = false
        deadline = nil
        hibernateRequestID = nil
    }
}

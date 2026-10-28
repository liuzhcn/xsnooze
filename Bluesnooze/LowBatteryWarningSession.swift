import Foundation

struct LowBatteryWarningSession {
    enum SoundCue: Int {
        case initial = 1
        case tenSeconds = 2
        case fiveSeconds = 3
    }

    private(set) var deadline: Date?
    private var hibernateRequestID: UUID?
    private var isSleeping = false
    private var soundStage = 0

    var canStartWarning: Bool {
        deadline == nil && hibernateRequestID == nil && !isSleeping
    }

    mutating func beginCountdown(seconds: Int, at now: Date = Date()) -> Bool {
        guard canStartWarning else {
            return false
        }
        deadline = now.addingTimeInterval(TimeInterval(seconds))
        soundStage = 0
        return true
    }

    mutating func consumeSoundCue(enabled: Bool, at now: Date = Date()) -> SoundCue? {
        guard let remaining = remainingSeconds(at: now) else {
            return nil
        }
        guard remaining > 0 else {
            soundStage = SoundCue.fiveSeconds.rawValue
            return nil
        }

        let cue: SoundCue
        if remaining <= 5 {
            cue = .fiveSeconds
        } else if remaining <= 10 {
            cue = .tenSeconds
        } else {
            cue = .initial
        }
        guard cue.rawValue > soundStage else {
            return nil
        }
        // Consume muted and skipped cues too: never replay them or catch up in a burst.
        soundStage = cue.rawValue
        return enabled ? cue : nil
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

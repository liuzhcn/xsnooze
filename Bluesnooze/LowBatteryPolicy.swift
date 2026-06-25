import Foundation

struct PowerSourceSnapshot: Equatable {
    let isBatteryPower: Bool
    let isCharging: Bool
    let chargePercentage: Int
}

struct LowBatterySettings: Equatable {
    static let isEnabledKey = "lowBatteryReminderEnabled"
    static let thresholdPercentageKey = "lowBatteryThresholdPercentage"
    static let forceHibernateOnTimeoutKey = "lowBatteryForceHibernateOnTimeout"
    static let countdownSecondsKey = "lowBatteryCountdownSeconds"

    static let defaultIsEnabled = true
    static let defaultThresholdPercentage = 30
    static let defaultForceHibernateOnTimeout = true
    static let defaultCountdownSeconds = 60
    static let thresholdRange = 10...40
    static let countdownRange = 15...300

    let isEnabled: Bool
    let thresholdPercentage: Int
    let forceHibernateOnTimeout: Bool
    let countdownSeconds: Int

    var canEditCountdown: Bool {
        isEnabled && forceHibernateOnTimeout
    }

    init(
        isEnabled: Bool = defaultIsEnabled,
        thresholdPercentage: Int = defaultThresholdPercentage,
        forceHibernateOnTimeout: Bool = defaultForceHibernateOnTimeout,
        countdownSeconds: Int = defaultCountdownSeconds
    ) {
        self.isEnabled = isEnabled
        self.thresholdPercentage = Self.clamp(thresholdPercentage, to: Self.thresholdRange)
        self.forceHibernateOnTimeout = forceHibernateOnTimeout
        self.countdownSeconds = Self.clamp(countdownSeconds, to: Self.countdownRange)
    }

    init(userDefaults: UserDefaults) {
        let isEnabled = userDefaults.object(forKey: Self.isEnabledKey) as? Bool ?? Self.defaultIsEnabled
        let thresholdPercentage = userDefaults.object(forKey: Self.thresholdPercentageKey) as? Int ?? Self.defaultThresholdPercentage
        let forceHibernateOnTimeout = userDefaults.object(forKey: Self.forceHibernateOnTimeoutKey) as? Bool ?? Self.defaultForceHibernateOnTimeout
        let countdownSeconds = userDefaults.object(forKey: Self.countdownSecondsKey) as? Int ?? Self.defaultCountdownSeconds

        self.init(
            isEnabled: isEnabled,
            thresholdPercentage: thresholdPercentage,
            forceHibernateOnTimeout: forceHibernateOnTimeout,
            countdownSeconds: countdownSeconds
        )
    }

    func save(to userDefaults: UserDefaults) {
        userDefaults.set(isEnabled, forKey: Self.isEnabledKey)
        userDefaults.set(thresholdPercentage, forKey: Self.thresholdPercentageKey)
        userDefaults.set(forceHibernateOnTimeout, forKey: Self.forceHibernateOnTimeoutKey)
        userDefaults.set(countdownSeconds, forKey: Self.countdownSecondsKey)
    }

    func with(
        isEnabled: Bool? = nil,
        thresholdPercentage: Int? = nil,
        forceHibernateOnTimeout: Bool? = nil,
        countdownSeconds: Int? = nil
    ) -> LowBatterySettings {
        LowBatterySettings(
            isEnabled: isEnabled ?? self.isEnabled,
            thresholdPercentage: thresholdPercentage ?? self.thresholdPercentage,
            forceHibernateOnTimeout: forceHibernateOnTimeout ?? self.forceHibernateOnTimeout,
            countdownSeconds: countdownSeconds ?? self.countdownSeconds
        )
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum LowBatteryPolicy {
    static func bucket(for chargePercentage: Int, settings: LowBatterySettings) -> Int? {
        guard settings.isEnabled,
              chargePercentage < settings.thresholdPercentage else {
            return nil
        }

        let firstBucket = settings.thresholdPercentage - 1
        if chargePercentage > firstBucket - 4 {
            return firstBucket
        }

        let roundedBucket = max(5, (chargePercentage / 5) * 5)
        return roundedBucket
    }

    static func shouldStartWarning(
        for snapshot: PowerSourceSnapshot,
        settings: LowBatterySettings,
        suppressedBucket: Int?
    ) -> Bool {
        guard settings.isEnabled,
              snapshot.isBatteryPower,
              !snapshot.isCharging,
              let bucket = bucket(for: snapshot.chargePercentage, settings: settings) else {
            return false
        }

        return bucket != suppressedBucket
    }

    static func bucket(for chargePercentage: Int) -> Int? {
        bucket(for: chargePercentage, settings: LowBatterySettings())
    }

    static func shouldStartWarning(for snapshot: PowerSourceSnapshot, suppressedBucket: Int?) -> Bool {
        shouldStartWarning(for: snapshot, settings: LowBatterySettings(), suppressedBucket: suppressedBucket)
    }
}

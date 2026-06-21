import Foundation

struct PowerSourceSnapshot: Equatable {
    let isBatteryPower: Bool
    let isCharging: Bool
    let chargePercentage: Int
}

enum LowBatteryPolicy {
    static let warningThreshold = 30
    static let warningBuckets = [29, 25, 20, 15, 10, 5]

    static func bucket(for chargePercentage: Int) -> Int? {
        guard chargePercentage < warningThreshold else {
            return nil
        }

        for index in warningBuckets.indices {
            let currentBucket = warningBuckets[index]
            let nextBucket = warningBuckets.index(after: index) < warningBuckets.endIndex ? warningBuckets[warningBuckets.index(after: index)] : Int.min

            if chargePercentage <= currentBucket && chargePercentage > nextBucket {
                return currentBucket
            }
        }

        return warningBuckets.last
    }

    static func shouldStartWarning(for snapshot: PowerSourceSnapshot, suppressedBucket: Int?) -> Bool {
        guard snapshot.isBatteryPower,
              !snapshot.isCharging,
              let bucket = bucket(for: snapshot.chargePercentage) else {
            return false
        }

        return bucket != suppressedBucket
    }
}

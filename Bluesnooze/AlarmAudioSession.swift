import Foundation

struct AlarmAudioControl: Codable, Equatable {
    enum Kind: String, Codable { case volume, mute }
    let kind: Kind
    let channel: UInt32
    let value: Float
}

struct AlarmAudioSnapshot {
    let deviceUID: String
    let controls: [AlarmAudioControl]
}

protocol AlarmAudioDeviceAccess {
    func currentOutputUID() throws -> String
    func snapshot() throws -> AlarmAudioSnapshot
    func read(_ control: AlarmAudioControl, deviceUID: String) throws -> Float
    func write(_ value: Float, control: AlarmAudioControl, deviceUID: String) throws
}

// Kept separate from playback so every early-exit and recovery path can be tested
// without changing the test machine's audio settings.
final class AlarmAudioSession {
    struct Change: Codable, Equatable {
        let deviceUID: String
        let original: AlarmAudioControl
        var applied: Float
    }

    enum Failure: Error { case restorationPending, unsupportedOutput, invalidVolume }
    private let devices: AlarmAudioDeviceAccess
    private let save: ([Change]) throws -> Void
    private(set) var pending: [Change]

    init(devices: AlarmAudioDeviceAccess, pending: [Change] = [], save: @escaping ([Change]) throws -> Void = { _ in }) {
        self.devices = devices
        self.pending = pending
        self.save = save
    }

    func begin(volume: Float) throws -> String {
        guard volume.isFinite, volume > 0, volume <= 1 else { throw Failure.invalidVolume }
        try restore()
        guard pending.isEmpty else { throw Failure.restorationPending }
        let snapshot = try devices.snapshot()
        guard snapshot.controls.contains(where: { $0.kind == .volume }) else { throw Failure.unsupportedOutput }
        do {
            // Snapshot all controls before mutation; set volume before unmuting.
            for control in snapshot.controls.sorted(by: { $0.kind == .volume && $1.kind == .mute }) {
                let target: Float = control.kind == .volume ? volume : 0
                guard abs(control.value - target) > 0.0001 else { continue }
                pending.append(Change(deviceUID: snapshot.deviceUID, original: control, applied: target))
                // Persist before touching the device, allowing recovery after a crash.
                try save(pending)
                try devices.write(target, control: control, deviceUID: snapshot.deviceUID)
                pending[pending.count - 1].applied = try devices.read(control, deviceUID: snapshot.deviceUID)
                try save(pending)
                guard abs(pending[pending.count - 1].applied - target) < 0.02 else { throw Failure.unsupportedOutput }
            }
            guard try devices.currentOutputUID() == snapshot.deviceUID else { throw Failure.unsupportedOutput }
            return snapshot.deviceUID
        } catch {
            try? restore()
            throw error
        }
    }

    func restore() throws {
        var remaining: [Change] = []
        var failure: Error?
        for change in pending.reversed() {
            do {
                let current = try devices.read(change.original, deviceUID: change.deviceUID)
                // Preserve a user's manual adjustment made while the sound played.
                if abs(current - change.applied) < 0.002 {
                    try devices.write(change.original.value, control: change.original, deviceUID: change.deviceUID)
                    let restored = try devices.read(change.original, deviceUID: change.deviceUID)
                    guard abs(restored - change.original.value) < 0.002 else { throw Failure.restorationPending }
                }
            } catch {
                remaining.append(change)
                failure = error
            }
        }
        pending = remaining.reversed()
        try save(pending)
        if let failure { throw failure }
    }
}

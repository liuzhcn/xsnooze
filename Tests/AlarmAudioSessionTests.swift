import Foundation

final class FakeAlarmDevices: AlarmAudioDeviceAccess {
    enum Failure: Error { case unavailable, write }
    var current = "speakers"
    var values: [String: [AlarmAudioControl]] = ["speakers": [
        AlarmAudioControl(kind: .volume, channel: 0, value: 0),
        AlarmAudioControl(kind: .mute, channel: 0, value: 1)
    ]]
    var failWriteNumber: Int?
    var writeCount = 0
    var disconnected = false
    func currentOutputUID() throws -> String { current }
    func snapshot() throws -> AlarmAudioSnapshot {
        guard let controls = values[current] else { throw Failure.unavailable }
        return AlarmAudioSnapshot(deviceUID: current, controls: controls)
    }
    func read(_ control: AlarmAudioControl, deviceUID: String) throws -> Float {
        guard !disconnected, let match = values[deviceUID]?.first(where: { $0.kind == control.kind && $0.channel == control.channel }) else { throw Failure.unavailable }
        return match.value
    }
    func write(_ value: Float, control: AlarmAudioControl, deviceUID: String) throws {
        writeCount += 1
        if writeCount == failWriteNumber { throw Failure.write }
        guard !disconnected, let index = values[deviceUID]?.firstIndex(where: { $0.kind == control.kind && $0.channel == control.channel }) else { throw Failure.unavailable }
        values[deviceUID]![index] = AlarmAudioControl(kind: control.kind, channel: control.channel, value: value)
    }
}

@main
struct AlarmAudioSessionTests {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() throws {
        try restoresZeroVolumeAndMute()
        try rollbackOnPartialFailure()
        try deviceSwitchRestoresOnlyOriginal()
        try manualChangesArePreserved()
        try persistedRecoveryAndReconnect()
        try stereoChannelsAndRepeatedStarts()
        unsupportedAndPersistenceFailureDoNotMutate()
        print("AlarmAudioSessionTests passed")
    }
    static func restoresZeroVolumeAndMute() throws {
        let devices = FakeAlarmDevices()
        let original = devices.values
        var saved: [AlarmAudioSession.Change] = []
        let session = AlarmAudioSession(devices: devices, save: { saved = $0 })
        _ = try session.begin(volume: 0.5)
        check(devices.values["speakers"]!.map(\.value) == [0.5, 0], "Alarm must override zero volume and mute")
        check(saved.count == 2, "Both changes must be recorded for recovery")
        try session.restore()
        check(devices.values == original, "Normal completion/cancellation must restore zero and mute exactly")
        check(saved.isEmpty, "Successful restore must clear recovery state")
        try session.restore()
        check(devices.values == original, "Repeated stop must be harmless")
    }
    static func rollbackOnPartialFailure() throws {
        let devices = FakeAlarmDevices()
        let original = devices.values
        devices.failWriteNumber = 2
        let session = AlarmAudioSession(devices: devices)
        do { _ = try session.begin(volume: 0.6); fatalError("Expected failure") } catch {}
        check(devices.values == original, "Unmute failure must roll back volume")
        check(session.pending.isEmpty, "Rolled-back failures must not leave an override")
    }
    static func deviceSwitchRestoresOnlyOriginal() throws {
        let devices = FakeAlarmDevices()
        devices.values["headphones"] = [AlarmAudioControl(kind: .volume, channel: 0, value: 0.2)]
        let original = devices.values
        let session = AlarmAudioSession(devices: devices)
        _ = try session.begin(volume: 0.5)
        devices.current = "headphones"
        try session.restore()
        check(devices.values == original, "Restore must address the saved device, never overwrite the new default")
    }
    static func manualChangesArePreserved() throws {
        let devices = FakeAlarmDevices()
        let session = AlarmAudioSession(devices: devices)
        _ = try session.begin(volume: 0.5)
        let volume = devices.values["speakers"]![0]
        try devices.write(0.25, control: volume, deviceUID: "speakers")
        try session.restore()
        check(devices.values["speakers"]!.map(\.value) == [0.25, 1], "Do not undo manual volume changes; still restore unchanged mute control")
    }
    static func persistedRecoveryAndReconnect() throws {
        let devices = FakeAlarmDevices()
        let original = devices.values
        var saved: [AlarmAudioSession.Change] = []
        let first = AlarmAudioSession(devices: devices, save: { saved = $0 })
        _ = try first.begin(volume: 0.5)
        let encoded = try JSONEncoder().encode(saved)
        let recovered = AlarmAudioSession(devices: devices, pending: try JSONDecoder().decode([AlarmAudioSession.Change].self, from: encoded), save: { saved = $0 })
        devices.disconnected = true
        do { try recovered.restore(); fatalError("Expected disconnected device") } catch {}
        check(saved.count == 2, "Unplugging must retain recovery state")
        devices.disconnected = false
        try recovered.restore()
        check(devices.values == original && saved.isEmpty, "Reconnect or next launch should restore recorded settings")
    }
    static func stereoChannelsAndRepeatedStarts() throws {
        let devices = FakeAlarmDevices()
        devices.values["speakers"] = [
            AlarmAudioControl(kind: .volume, channel: 1, value: 0.2),
            AlarmAudioControl(kind: .volume, channel: 2, value: 0.4)
        ]
        let original = devices.values
        let session = AlarmAudioSession(devices: devices)
        _ = try session.begin(volume: 0.5)
        _ = try session.begin(volume: 0.7)
        try session.restore()
        check(devices.values == original, "Restarting an alarm must retain original channel levels and balance")
    }
    static func unsupportedAndPersistenceFailureDoNotMutate() {
        let devices = FakeAlarmDevices()
        let original = devices.values
        let session = AlarmAudioSession(devices: devices, save: { _ in throw FakeAlarmDevices.Failure.write })
        do { _ = try session.begin(volume: 0.5); fatalError("Expected persistence failure") } catch {}
        check(devices.values == original && devices.writeCount == 0, "Never change volume if recovery state cannot be saved")
        devices.values["speakers"] = []
        let unsupported = AlarmAudioSession(devices: devices)
        do { _ = try unsupported.begin(volume: 0.5); fatalError("Expected unsupported device") } catch {}
        check(devices.writeCount == 0, "Unsupported output must not be mutated")
    }
}

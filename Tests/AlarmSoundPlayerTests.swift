import AppKit

private final class TestSound: AlarmSoundPlayback {
    var acceptsPlayback = true
    var active = false
    func play() -> Bool { active = acceptsPlayback; return active }
    func stop() -> Bool { active = false; return true }
    var isPlaying: Bool { active }
    var playbackDeviceIdentifier: String?
    var volume: Float = 1
    var loops = false
}

private final class TestAudioDevices: AlarmAudioDeviceAccess {
    var current = "original"
    var volume: Float = 0.2
    var mute: Float = 1
    func currentOutputUID() throws -> String { current }
    func snapshot() throws -> AlarmAudioSnapshot {
        AlarmAudioSnapshot(deviceUID: current, controls: [
            AlarmAudioControl(kind: .volume, channel: 0, value: volume),
            AlarmAudioControl(kind: .mute, channel: 0, value: mute)
        ])
    }
    func read(_ control: AlarmAudioControl, deviceUID: String) throws -> Float {
        precondition(deviceUID == "original", "Must restore the original device")
        return control.kind == .volume ? volume : mute
    }
    func write(_ value: Float, control: AlarmAudioControl, deviceUID: String) throws {
        precondition(deviceUID == "original", "Must not mutate the new output device")
        if control.kind == .volume { volume = value } else { mute = value }
    }
}

@main
struct AlarmSoundPlayerTests {
    static func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func main() {
        _ = NSApplication.shared
        for scenario in ["failure", "cancel", "deadline", "outputChange", "playbackEnds", "missingSound", "expired"] {
            let devices = TestAudioDevices()
            let sound = TestSound()
            sound.acceptsPlayback = scenario != "failure"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("XSnooze-PlayerTests-\(UUID().uuidString).json")
            let player = AlarmSoundPlayer(devices: devices, sound: scenario == "missingSound" ? nil : sound, recoveryURL: url, log: { _ in })
            let started = player.play(volumePercentage: 50, remainingSeconds: scenario == "expired" ? 0 : 1)
            if scenario == "failure" || scenario == "missingSound" || scenario == "expired" {
                check(!started, "Failed or missing sound must report failure")
            } else {
                check(started && devices.volume == 0.5 && devices.mute == 0, "Playback must apply alarm settings")
                check(sound.loops, "Playback must loop continuously")
                if scenario == "cancel" { player.stop() }
                if scenario == "outputChange" { devices.current = "new output" }
                if scenario == "playbackEnds" { sound.active = false }
                if scenario != "cancel" {
                    // Exercise the actual watchdog timer in the modal run-loop mode.
                    let end = Date().addingTimeInterval(1.3)
                    while Date() < end {
                        RunLoop.main.run(mode: .modalPanel, before: min(end, Date().addingTimeInterval(0.1)))
                    }
                }
            }
            check(!sound.isPlaying, "Audio must stop for \(scenario)")
            check(devices.volume == 0.2 && devices.mute == 1, "Settings must be restored for \(scenario)")
            check(!FileManager.default.fileExists(atPath: url.path), "Recovery file must clear for \(scenario)")
            player.stop()
        }
        print("AlarmSoundPlayerTests passed (7 playback/restore scenarios)")
    }
}

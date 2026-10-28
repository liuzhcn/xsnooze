import AppKit
import CoreAudio

final class CoreAudioAlarmDevices: AlarmAudioDeviceAccess {
    enum Failure: Error { case audio(OSStatus), unavailable, unsupported }

    private func address(_ selector: AudioObjectPropertySelector, channel: UInt32 = 0,
                         scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: channel)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure.audio(status) }
    }

    private func currentOutput() throws -> AudioDeviceID {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout.size(ofValue: device))
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device))
        guard device != kAudioObjectUnknown else { throw Failure.unavailable }
        return device
    }

    private func uid(_ device: AudioDeviceID) throws -> String {
        var property = address(kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value))
        guard let value else { throw Failure.unavailable }
        return value.takeRetainedValue() as String
    }

    func currentOutputUID() throws -> String { try uid(currentOutput()) }

    private func device(for deviceUID: String) throws -> AudioDeviceID {
        var property = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size))
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(system, &property, 0, nil, &size, &devices))
        guard let device = devices.first(where: { (try? uid($0)) == deviceUID }) else { throw Failure.unavailable }
        return device
    }

    private func property(for control: AlarmAudioControl) -> AudioObjectPropertyAddress {
        address(control.kind == .volume ? kAudioDevicePropertyVolumeScalar : kAudioDevicePropertyMute, channel: control.channel)
    }

    func read(_ control: AlarmAudioControl, deviceUID: String) throws -> Float {
        try read(control, device: device(for: deviceUID))
    }

    private func read(_ control: AlarmAudioControl, device: AudioDeviceID) throws -> Float {
        var property = property(for: control)
        var size: UInt32 = 4
        if control.kind == .mute {
            var value: UInt32 = 0
            try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value))
            return Float(value)
        }
        var value: Float = 0
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value))
        guard value.isFinite, (0...1).contains(value) else { throw Failure.unsupported }
        return value
    }

    func write(_ value: Float, control: AlarmAudioControl, deviceUID: String) throws {
        let device = try device(for: deviceUID)
        var property = property(for: control)
        if control.kind == .mute {
            var flag: UInt32 = value == 0 ? 0 : 1
            try check(AudioObjectSetPropertyData(device, &property, 0, nil, 4, &flag))
        } else {
            var scalar = value
            try check(AudioObjectSetPropertyData(device, &property, 0, nil, 4, &scalar))
        }
    }

    func snapshot() throws -> AlarmAudioSnapshot {
        let device = try currentOutput()
        let deviceUID = try uid(device)
        var controls: [AlarmAudioControl] = []
        // Prefer a master control; stereo channel controls cover devices without it.
        for kind: AlarmAudioControl.Kind in [.volume, .mute] {
            let master = AlarmAudioControl(kind: kind, channel: 0, value: 0)
            var masterProperty = property(for: master)
            let channels: [UInt32] = AudioObjectHasProperty(device, &masterProperty) ? [0] : [1, 2]
            for channel in channels {
                let control = AlarmAudioControl(kind: kind, channel: channel, value: 0)
                var property = property(for: control)
                guard AudioObjectHasProperty(device, &property) else { continue }
                var writable: DarwinBoolean = false
                try check(AudioObjectIsPropertySettable(device, &property, &writable))
                guard writable.boolValue else { throw Failure.unsupported }
                controls.append(AlarmAudioControl(kind: kind, channel: channel, value: try read(control, device: device)))
            }
        }
        guard controls.contains(where: { $0.kind == .volume }) else { throw Failure.unsupported }
        return AlarmAudioSnapshot(deviceUID: deviceUID, controls: controls)
    }
}

protocol AlarmSoundPlayback: AnyObject {
    var playbackDeviceIdentifier: String? { get set }
    var volume: Float { get set }
    var loops: Bool { get set }
    var isPlaying: Bool { get }
    @discardableResult func play() -> Bool
    @discardableResult func stop() -> Bool
}

extension NSSound: AlarmSoundPlayback {}

final class AlarmSoundPlayer {
    private let devices: AlarmAudioDeviceAccess
    private let sound: AlarmSoundPlayback?
    private let session: AlarmAudioSession?
    private let log: (String) -> Void
    private var timer: Timer?
    private var playbackDeviceUID: String?
    private var playbackStartedAt: Date?
    private var playbackDuration: TimeInterval = 0

    init(devices: AlarmAudioDeviceAccess = CoreAudioAlarmDevices(),
         sound: AlarmSoundPlayback? = NSSound(named: NSSound.Name("Glass")),
         recoveryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/XSnooze/alarm-audio-recovery.json"),
         log: @escaping (String) -> Void) {
        self.devices = devices
        self.sound = sound
        self.log = log
        do {
            let pending: [AlarmAudioSession.Change]
            if FileManager.default.fileExists(atPath: recoveryURL.path) {
                pending = try JSONDecoder().decode([AlarmAudioSession.Change].self, from: Data(contentsOf: recoveryURL))
            } else {
                pending = []
            }
            session = AlarmAudioSession(devices: devices, pending: pending) { changes in
                if changes.isEmpty {
                    if FileManager.default.fileExists(atPath: recoveryURL.path) {
                        try FileManager.default.removeItem(at: recoveryURL)
                    }
                } else {
                    try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(changes).write(to: recoveryURL, options: .atomic)
                }
            }
        } catch {
            session = nil
            log("Alarm audio recovery state could not be loaded: \(error)")
        }
        stop()
    }

    @discardableResult
    func play(volumePercentage: Int, remainingSeconds: Int) -> Bool {
        stop()
        guard remainingSeconds > 0, let session, let sound else { return false }
        do {
            let uid = try session.begin(volume: Float(min(100, max(10, volumePercentage))) / 100)
            playbackDeviceUID = uid
            sound.playbackDeviceIdentifier = uid
            sound.volume = 1
            sound.loops = true
            playbackDuration = TimeInterval(min(30, max(0, remainingSeconds)))
            playbackStartedAt = Date()
            guard sound.play() else {
                log("Alarm sound playback failed; restoring audio settings.")
                stop()
                return false
            }
            startTimer()
            return true
        } catch {
            log("Alarm sound unavailable; countdown continues: \(error)")
            stop()
            return false
        }
    }

    func stop() {
        sound?.stop()
        playbackDeviceUID = nil
        playbackStartedAt = nil
        timer?.invalidate()
        timer = nil
        do {
            try session?.restore()
        } catch {
            log("Alarm audio restoration pending (will retry): \(error)")
        }
        if session?.pending.isEmpty == false { startTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: playbackDeviceUID == nil ? 2 : 0.1, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func poll() {
        guard let uid = playbackDeviceUID, let startedAt = playbackStartedAt else {
            // An unplugged device may return later; use its UID, never the new default.
            do { try session?.restore() } catch { return }
            timer?.invalidate()
            timer = nil
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let timeout = playbackDuration
        if (try? devices.currentOutputUID()) != uid || elapsed >= timeout ||
            (elapsed > 0.15 && sound?.isPlaying != true) {
            stop()
        }
    }
}

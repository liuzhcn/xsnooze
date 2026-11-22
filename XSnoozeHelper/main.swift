import Foundation
import OSLog
import XPC

private let helperLog = Logger(subsystem: "com.liuzhcn.XSnooze.Helper", category: "hibernate")

private let stateFileURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.liuzhcn.XSnooze.Helper.state.plist")

final class HelperService {
    func prepareHibernateAndSleep(_ reply: @escaping (Bool, String?) -> Void) {
        helperLog.info("Preparing forced hibernation and sleep.")
        do {
            let originalMode = try currentBatteryHibernateMode()
            helperLog.info("Read current Battery Power hibernatemode. originalMode=\(originalMode, privacy: .public)")
            try saveOriginalHibernateMode(originalMode)
            helperLog.info("Saved original Battery Power hibernatemode.")
            try runPMSet(arguments: ["-b", "hibernatemode", "25"])
            helperLog.info("Set Battery Power hibernatemode for forced hibernation.")
            try runPMSet(arguments: ["sleepnow"])
            helperLog.info("Issued sleepnow command for forced hibernation.")
            reply(true, nil)
        } catch {
            helperLog.error("Failed to prepare forced hibernation and sleep. error=\(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func restoreHibernationModeIfNeeded(_ reply: @escaping (Bool, String?) -> Void) {
        helperLog.info("Checking whether Battery Power hibernatemode needs to be restored.")
        do {
            guard let originalMode = try savedOriginalHibernateMode() else {
                helperLog.info("No saved Battery Power hibernatemode found; nothing to restore.")
                reply(true, "No saved hibernatemode to restore.")
                return
            }

            helperLog.info("Restoring saved Battery Power hibernatemode. originalMode=\(originalMode, privacy: .public)")
            try runPMSet(arguments: ["-b", "hibernatemode", "\(originalMode)"])
            try FileManager.default.removeItem(at: stateFileURL)
            helperLog.info("Restored Battery Power hibernatemode and removed saved state.")
            reply(true, nil)
        } catch {
            helperLog.error("Failed to restore Battery Power hibernatemode. error=\(error.localizedDescription, privacy: .public)")
            reply(false, error.localizedDescription)
        }
    }

    func status(_ reply: @escaping (Bool, String?) -> Void) {
        do {
            let mode = try currentBatteryHibernateMode()
            reply(true, "Battery Power hibernatemode is \(mode).")
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    private func currentBatteryHibernateMode() throws -> Int {
        let output = try runPMSet(arguments: ["-g", "custom"])
        var isBatterySection = false

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Battery Power") {
                isBatterySection = true
                continue
            }

            if line.hasPrefix("AC Power") {
                isBatterySection = false
                continue
            }

            guard isBatterySection, line.hasPrefix("hibernatemode") else {
                continue
            }

            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, let mode = Int(parts[1]) {
                return mode
            }
        }

        throw HelperError.unableToReadHibernateMode
    }

    private func saveOriginalHibernateMode(_ mode: Int) throws {
        let payload: [String: Any] = [
            "originalHibernateMode": mode,
            "savedAt": Date()
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        try data.write(to: stateFileURL, options: .atomic)
    }

    private func savedOriginalHibernateMode() throws -> Int? {
        guard FileManager.default.fileExists(atPath: stateFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: stateFileURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw HelperError.invalidSavedState
        }

        return dictionary["originalHibernateMode"] as? Int
    }

    @discardableResult
    private func runPMSet(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw HelperError.pmsetFailed(arguments.joined(separator: " "), errorOutput)
        }

        return output
    }
}

final class HelperListener {
    private let service = HelperService()
    private let queue = DispatchQueue(label: "com.liuzhcn.XSnooze.Helper.requests")
    private let requirement: String

    init(requirement: String) {
        self.requirement = requirement
    }

    func start() -> Bool {
        let listener = xpc_connection_create_mach_service(
            privilegedHelperMachServiceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        guard HelperIdentity.requirePeer(listener, requirement: requirement) else {
            xpc_connection_cancel(listener)
            return false
        }
        xpc_connection_set_event_handler(listener) { [self] event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            let peer = event
            xpc_connection_set_target_queue(peer, queue)
            xpc_connection_set_event_handler(peer) { [self] request in
                guard xpc_get_type(request) == XPC_TYPE_DICTIONARY,
                      let reply = xpc_dictionary_create_reply(request) else { return }
                let respond: (Bool, String?) -> Void = { success, message in
                    xpc_dictionary_set_bool(reply, "success", success)
                    if let message { xpc_dictionary_set_string(reply, "message", message) }
                    xpc_connection_send_message(peer, reply)
                }
                guard let rawCommand = xpc_dictionary_get_string(request, "command"),
                      let command = HelperCommand(rawValue: String(cString: rawCommand)) else {
                    respond(false, "Unsupported helper command.")
                    return
                }
                switch command {
                case .prepareHibernateAndSleep: service.prepareHibernateAndSleep(respond)
                case .restoreHibernationModeIfNeeded: service.restoreHibernationModeIfNeeded(respond)
                case .status: service.status(respond)
                }
            }
            xpc_connection_resume(peer)
        }
        xpc_connection_resume(listener)
        // Retain the listener for the lifetime of the process.
        self.listener = listener
        return true
    }

    private var listener: xpc_connection_t?
}

enum HelperError: LocalizedError {
    case unableToReadHibernateMode
    case invalidSavedState
    case pmsetFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unableToReadHibernateMode:
            return "Unable to read Battery Power hibernatemode from pmset."
        case .invalidSavedState:
            return "Saved hibernatemode state is invalid."
        case let .pmsetFailed(arguments, errorOutput):
            return "pmset \(arguments) failed: \(errorOutput)"
        }
    }
}

// launchd supplies the pin from the root-owned installation configuration.
// A missing or invalid pin must never start an unrestricted listener.
guard geteuid() == 0, let requirement = HelperIdentity.clientRequirement(arguments: CommandLine.arguments) else {
    helperLog.error("Missing or invalid trusted client identity; refusing to start.")
    exit(EXIT_FAILURE)
}
let listener = HelperListener(requirement: requirement)
guard listener.start() else {
    helperLog.error("Unable to enforce trusted client identity; refusing to start.")
    exit(EXIT_FAILURE)
}
dispatchMain()

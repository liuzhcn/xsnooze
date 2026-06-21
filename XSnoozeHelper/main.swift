import Foundation

private let stateFileURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.liuzhcn.XSnooze.Helper.state.plist")

final class HelperService: NSObject, PrivilegedHelperProtocol {
    func prepareHibernateAndSleep(_ reply: @escaping (Bool, String?) -> Void) {
        do {
            let originalMode = try currentBatteryHibernateMode()
            try saveOriginalHibernateMode(originalMode)
            try runPMSet(arguments: ["-b", "hibernatemode", "25"])
            try runPMSet(arguments: ["sleepnow"])
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func restoreHibernationModeIfNeeded(_ reply: @escaping (Bool, String?) -> Void) {
        do {
            guard let originalMode = try savedOriginalHibernateMode() else {
                reply(true, "No saved hibernatemode to restore.")
                return
            }

            try runPMSet(arguments: ["-b", "hibernatemode", "\(originalMode)"])
            try FileManager.default.removeItem(at: stateFileURL)
            reply(true, nil)
        } catch {
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

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
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

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: privilegedHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()


import Foundation
import OSLog
import XPC

private let hibernateLog = Logger(subsystem: "com.liuzhcn.XSnooze", category: "hibernate")

final class PrivilegedHelperClient {
    private static let unavailableMessage = NSLocalizedString(
        "Install the matching XSnooze Helper using install-helper.command, then try again.",
        comment: "Privileged helper missing or signature mismatch"
    )

    func prepareHibernateAndSleep(completion: @escaping (Bool, String?) -> Void) {
        hibernateLog.info("Calling privileged helper to prepare hibernation and sleep.")
        callHelper(.prepareHibernateAndSleep, completion: completion)
    }

    func restoreHibernationModeIfNeeded() {
        callHelper(.restoreHibernationModeIfNeeded) { success, message in
            if success {
                hibernateLog.info("Privileged helper restore hibernatemode request succeeded.")
            } else {
                hibernateLog.warning("Privileged helper restore unavailable. message=\(message ?? "Unknown error", privacy: .public)")
            }
        }
    }

    func status(completion: @escaping (Bool, String?) -> Void) {
        callHelper(.status, completion: completion)
    }

    private func callHelper(_ command: HelperCommand, completion: @escaping (Bool, String?) -> Void) {
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(privilegedHelperMachServiceName)")
        guard let requirement = HelperIdentity.bundledHelperRequirement(at: helperURL) else {
            completion(false, Self.unavailableMessage)
            return
        }

        let connection = xpc_connection_create_mach_service(
            privilegedHelperMachServiceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
        )
        guard HelperIdentity.requirePeer(connection, requirement: requirement) else {
            xpc_connection_cancel(connection)
            completion(false, Self.unavailableMessage)
            return
        }
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)

        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(request, "command", command.rawValue)
        let timeout = DispatchWorkItem { xpc_connection_cancel(connection) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        xpc_connection_send_message_with_reply(connection, request, nil) { reply in
            defer {
                timeout.cancel()
                xpc_connection_cancel(connection)
            }
            guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
                  let success = xpc_dictionary_get_value(reply, "success"),
                  xpc_get_type(success) == XPC_TYPE_BOOL else {
                completion(false, Self.unavailableMessage)
                return
            }
            let message = xpc_dictionary_get_string(reply, "message").map { String(cString: $0) }
            completion(xpc_bool_get_value(success), message)
        }
    }
}

import Foundation
import OSLog
import Security
import ServiceManagement

private let hibernateLog = Logger(subsystem: "com.liuzhcn.XSnooze", category: "hibernate")

final class PrivilegedHelperClient {
    func prepareHibernateAndSleep(completion: @escaping (Bool, String?) -> Void) {
        hibernateLog.info("Calling privileged helper to prepare hibernation and sleep.")
        callHelper({ helper, connection in
            helper.prepareHibernateAndSleep { success, message in
                connection.invalidate()
                if success {
                    hibernateLog.info("Privileged helper prepared hibernation and sleep successfully.")
                } else {
                    hibernateLog.error("Privileged helper failed to prepare hibernation and sleep. message=\(message ?? "Unknown error", privacy: .public)")
                }
                completion(success, message)
            }
        }, unavailable: { [weak self] message in
            hibernateLog.warning("Privileged helper unavailable; attempting to install helper. message=\(message, privacy: .public)")
            self?.blessHelper { blessSuccess, blessMessage in
                guard blessSuccess else {
                    hibernateLog.error("Privileged helper installation failed. message=\(blessMessage ?? "Unknown error", privacy: .public)")
                    completion(false, blessMessage)
                    return
                }

                hibernateLog.info("Privileged helper installation succeeded; retrying hibernation request.")
                self?.callHelper({ helper, connection in
                    helper.prepareHibernateAndSleep { retrySuccess, retryMessage in
                        connection.invalidate()
                        if retrySuccess {
                            hibernateLog.info("Privileged helper prepared hibernation and sleep successfully after installation.")
                        } else {
                            hibernateLog.error("Privileged helper failed to prepare hibernation and sleep after installation. message=\(retryMessage ?? "Unknown error", privacy: .public)")
                        }
                        completion(retrySuccess, retryMessage)
                    }
                }, unavailable: { retryMessage in
                    hibernateLog.error("Privileged helper unavailable after installation. message=\(retryMessage, privacy: .public)")
                    completion(false, retryMessage)
                })
            }
        })
    }

    func restoreHibernationModeIfNeeded() {
        hibernateLog.info("Calling privileged helper to restore hibernatemode if needed.")
        callHelper({ helper, connection in
            helper.restoreHibernationModeIfNeeded { success, message in
                connection.invalidate()
                if success {
                    hibernateLog.info("Privileged helper restore hibernatemode request succeeded. message=\(message ?? "Restored if needed.", privacy: .public)")
                } else if let message {
                    hibernateLog.error("Failed to restore hibernatemode. message=\(message, privacy: .public)")
                } else {
                    hibernateLog.error("Failed to restore hibernatemode. message=Unknown error")
                }
            }
        }, unavailable: { message in
            hibernateLog.warning("Privileged helper restore unavailable. message=\(message, privacy: .public)")
        })
    }

    func status(completion: @escaping (Bool, String?) -> Void) {
        callHelper({ helper, connection in
            helper.status { success, message in
                connection.invalidate()
                completion(success, message)
            }
        }, unavailable: { message in
            completion(false, message)
        })
    }

    private func callHelper(
        _ action: @escaping (PrivilegedHelperProtocol, NSXPCConnection) -> Void,
        unavailable: @escaping (String) -> Void
    ) {
        let connection = NSXPCConnection(machServiceName: privilegedHelperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            connection.invalidate()
            unavailable(error.localizedDescription)
        } as? PrivilegedHelperProtocol

        guard let proxy else {
            connection.invalidate()
            unavailable("Unable to create privileged helper proxy.")
            return
        }

        action(proxy, connection)
    }

    private func blessHelper(completion: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var authorizationRef: AuthorizationRef?
            var status = AuthorizationCreate(nil, nil, [], &authorizationRef)

            guard status == errAuthorizationSuccess, let authorizationRef else {
                DispatchQueue.main.async {
                    completion(false, "Authorization failed with status \(status).")
                }
                return
            }

            defer {
                AuthorizationFree(authorizationRef, [])
            }

            let blessed: Bool
            let message: String?

            let rightName = kSMRightBlessPrivilegedHelper
            status = rightName.withCString { rightNamePointer in
                var authItem = AuthorizationItem(
                    name: rightNamePointer,
                    valueLength: 0,
                    value: nil,
                    flags: 0
                )
                return withUnsafeMutablePointer(to: &authItem) { authItemPointer in
                    var authRights = AuthorizationRights(count: 1, items: authItemPointer)
                    let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
                    return AuthorizationCopyRights(authorizationRef, &authRights, nil, flags, nil)
                }
            }

            guard status == errAuthorizationSuccess else {
                DispatchQueue.main.async {
                    completion(false, "Authorization rights failed with status \(status).")
                }
                return
            }

            var unmanagedError: Unmanaged<CFError>?
            blessed = SMJobBless(
                kSMDomainSystemLaunchd,
                privilegedHelperMachServiceName as CFString,
                authorizationRef,
                &unmanagedError
            )
            message = unmanagedError?.takeRetainedValue().localizedDescription

            DispatchQueue.main.async {
                completion(blessed, message)
            }
        }
    }
}

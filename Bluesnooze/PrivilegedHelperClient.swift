import Foundation
import Security
import ServiceManagement

final class PrivilegedHelperClient {
    func prepareHibernateAndSleep(completion: @escaping (Bool, String?) -> Void) {
        callHelper({ helper, connection in
            helper.prepareHibernateAndSleep { success, message in
                connection.invalidate()
                completion(success, message)
            }
        }, unavailable: { [weak self] message in
            self?.blessHelper { blessSuccess, blessMessage in
                guard blessSuccess else {
                    completion(false, blessMessage)
                    return
                }

                self?.callHelper({ helper, connection in
                    helper.prepareHibernateAndSleep { retrySuccess, retryMessage in
                        connection.invalidate()
                        completion(retrySuccess, retryMessage)
                    }
                }, unavailable: { retryMessage in
                    completion(false, retryMessage)
                })
            }
        })
    }

    func restoreHibernationModeIfNeeded() {
        callHelper({ helper, connection in
            helper.restoreHibernationModeIfNeeded { success, message in
                connection.invalidate()
                if !success, let message {
                    NSLog("XSnooze: Failed to restore hibernatemode: \(message)")
                }
            }
        }, unavailable: { message in
            NSLog("XSnooze: Privileged helper restore unavailable: \(message)")
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

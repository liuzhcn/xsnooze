import Foundation
import Security
import XPC

let privilegedHelperMachServiceName = "com.liuzhcn.XSnooze.Helper"
let privilegedHelperClientIdentifier = "com.liuzhcn.XSnooze"

enum HelperCommand: String {
    case prepareHibernateAndSleep
    case restoreHibernationModeIfNeeded
    case status
}

enum HelperIdentity {
    // Ad-hoc signatures have no certificate identity. The installer pins the
    // signed app's CodeDirectory hash and renews that pin on every upgrade.
    static func requirement(identifier: String, cdHash: String) -> String? {
        guard [privilegedHelperClientIdentifier, privilegedHelperMachServiceName].contains(identifier),
              cdHash.utf8.count == 40,
              cdHash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        return "identifier \"\(identifier)\" and cdhash H\"\(cdHash.lowercased())\""
    }

    static func clientRequirement(arguments: [String]) -> String? {
        guard arguments.count == 3, arguments[1] == "--client-cdhash" else {
            return nil
        }
        return requirement(identifier: privilegedHelperClientIdentifier, cdHash: arguments[2])
    }

    static func bundledHelperRequirement(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              info[kSecCodeInfoIdentifier as String] as? String == privilegedHelperMachServiceName,
              let hash = info[kSecCodeInfoUnique as String] as? Data else {
            return nil
        }
        return requirement(identifier: privilegedHelperMachServiceName, cdHash: hash.map { String(format: "%02x", $0) }.joined())
    }

    // XPC validates messages against the peer's signature on macOS 12+.
    static func requirePeer(_ connection: xpc_connection_t, requirement: String) -> Bool {
        requirement.withCString { xpc_connection_set_peer_code_signing_requirement(connection, $0) == 0 }
    }
}


import Foundation
import Security
import XPC

@main
struct HelperIdentityTests {
    static func main() {
        let hash = String(repeating: "AB", count: 20)
        let expected = "identifier \"com.liuzhcn.XSnooze\" and cdhash H\"\(hash.lowercased())\""
        precondition(HelperIdentity.clientRequirement(arguments: ["helper", "--client-cdhash", hash]) == expected)
        precondition(HelperIdentity.clientRequirement(arguments: ["helper"]) == nil)
        precondition(HelperIdentity.clientRequirement(arguments: ["helper", "--unexpected", hash]) == nil)
        precondition(HelperIdentity.clientRequirement(arguments: ["helper", "--client-cdhash", hash, "extra"]) == nil)
        for invalid in ["", String(hash.dropLast()), hash + "A", String(repeating: "x", count: 40), "\"" + hash] {
            precondition(HelperIdentity.clientRequirement(arguments: ["helper", "--client-cdhash", invalid]) == nil)
        }
        precondition(HelperIdentity.requirement(identifier: "unrelated", cdHash: hash) == nil)
        var compiled: SecRequirement?
        precondition(SecRequirementCreateWithString(expected as CFString, [], &compiled) == errSecSuccess)
        precondition(compiled != nil)
        checkProtectedXPCConnection(matches: true)
        checkProtectedXPCConnection(matches: false)

        // Check the actual packaged helper's signature and identifier using Security.framework.
        if CommandLine.arguments.count == 2 {
            let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let helper = app.appendingPathComponent("Contents/Library/LaunchServices/\(privilegedHelperMachServiceName)")
            guard let requirement = HelperIdentity.bundledHelperRequirement(at: helper) else {
                fatalError("Packaged helper signature could not be read")
            }
            precondition(HelperIdentity.bundledHelperRequirement(at: app) == nil, "The app identifier is not the helper identifier")
            precondition(HelperIdentity.bundledHelperRequirement(at: helper.appendingPathExtension("missing")) == nil)
            precondition(SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess)
            var code: SecStaticCode?
            precondition(SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess)
            precondition(SecStaticCodeCheckValidity(code!, [], compiled) == errSecSuccess)
        }
        print("HelperIdentityTests passed")
    }

    // An anonymous, unprivileged test listener verifies that the system's XPC
    // requirement accepts the signed test process. No sleep commands are sent.
    private static func checkProtectedXPCConnection(matches: Bool) {
        var code: SecStaticCode?
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        precondition(SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess)
        var information: CFDictionary?
        precondition(SecCodeCopySigningInformation(code!, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess)
        let hash = (information as! [String: Any])[kSecCodeInfoUnique as String] as! Data
        let hashText = hash.map { String(format: "%02x", $0) }.joined()
        let requirement = "cdhash H\"\(hashText)\""
        let listenerRequirement = matches ? requirement : "cdhash H\"\(String(repeating: "0", count: 40))\""
        let handled = DispatchSemaphore(value: 0)

        let listener = xpc_connection_create(nil, nil)
        precondition(HelperIdentity.requirePeer(listener, requirement: listenerRequirement))
        xpc_connection_set_event_handler(listener) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            xpc_connection_set_event_handler(peer) { request in
                guard xpc_get_type(request) == XPC_TYPE_DICTIONARY,
                      let reply = xpc_dictionary_create_reply(request) else { return }
                handled.signal()
                xpc_dictionary_set_bool(reply, "success", true)
                xpc_connection_send_message(peer, reply)
            }
            xpc_connection_resume(peer)
        }
        xpc_connection_resume(listener)
        let client = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
        precondition(HelperIdentity.requirePeer(client, requirement: requirement))
        xpc_connection_set_event_handler(client) { _ in }
        xpc_connection_resume(client)
        let completed = DispatchSemaphore(value: 0)
        let request = xpc_dictionary_create(nil, nil, 0)
        xpc_connection_send_message_with_reply(client, request, nil) { reply in
            if matches && (xpc_get_type(reply) != XPC_TYPE_DICTIONARY || !xpc_dictionary_get_bool(reply, "success")) {
                let description = xpc_copy_description(reply)
                defer { free(description) }
                fatalError("Protected XPC reply failed: \(String(cString: description))")
            }
            completed.signal()
        }
        if matches {
            precondition(completed.wait(timeout: .now() + 5) == .success, "Protected XPC reply timed out")
            precondition(handled.wait(timeout: .now()) == .success)
        } else {
            precondition(handled.wait(timeout: .now() + 2) == .timedOut, "A connection with an unmatched signature was accepted")
        }
        xpc_connection_cancel(client)
        xpc_connection_cancel(listener)
    }
}

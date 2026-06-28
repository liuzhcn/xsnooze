import Foundation

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fatalError("\(message): expected \(expected), got \(actual)")
    }
}

@main
struct LogViewerPolicyTests {
    static func main() {
        assertEqual(
            XSnoozeLogQuery.arguments,
            [
                "show",
                "--style",
                "compact",
                "--last",
                "24h",
                "--predicate",
                "subsystem == \"com.liuzhcn.XSnooze\""
            ],
            "Log viewer should request recent XSnooze default/notice logs"
        )
        assertEqual(XSnoozeLogQuery.executablePath, "/usr/bin/log", "Log viewer should use the system log tool")
    }
}

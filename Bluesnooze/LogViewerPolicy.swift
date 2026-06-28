import Foundation

enum XSnoozeLogQuery {
    static let executablePath = "/usr/bin/log"
    static let subsystem = "com.liuzhcn.XSnooze"
    static let lookback = "24h"

    static var arguments: [String] {
        [
            "show",
            "--style",
            "compact",
            "--last",
            lookback,
            "--predicate",
            "subsystem == \"\(subsystem)\""
        ]
    }
}

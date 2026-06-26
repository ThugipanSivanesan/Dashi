import Foundation
import os

/// Scrubs secret-shaped substrings from text before it is logged. Defense-in-depth alongside
/// ``Secret`` and the Keychain: even if a raw key reaches a log call, it is masked here.
public struct Redactor: Sendable {
    private let patterns: [NSRegularExpression]
    private let literals: [String]

    /// - Parameter seedSecrets: exact plaintext values currently in use (e.g. provider keys read
    ///   from the Keychain at startup). These are matched literally in addition to the shape regexes.
    public init(seedSecrets: [String] = []) {
        let shapes = [
            #"sk-ant-[A-Za-z0-9_\-]{16,}"#,
            #"sk-[A-Za-z0-9_\-]{16,}"#,
            #"Bearer\s+[A-Za-z0-9._\-]+"#,
            #"\b[0-9a-f]{64}\b"#,
            #"\b[1-9A-HJ-NP-Za-km-z]{40,90}\b"#,
        ]
        patterns = shapes.compactMap { try? NSRegularExpression(pattern: $0) }
        // Longest-first so a key isn't partially masked by a shorter overlapping value.
        literals = seedSecrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    public func redact(_ input: String) -> String {
        var output = input
        for literal in literals {
            output = output.replacingOccurrences(of: literal, with: "***")
        }
        for pattern in patterns {
            let range = NSRange(output.startIndex..., in: output)
            output = pattern.stringByReplacingMatches(in: output, range: range, withTemplate: "***")
        }
        return output
    }
}

/// Thin wrapper over `os.Logger` that runs every message through a ``Redactor`` first. Install one
/// instance at startup seeded from the secrets in use and route all app logging through it.
public struct RedactingLog: Sendable {
    private let logger: Logger
    private let redactor: Redactor

    public init(subsystem: String = "com.dashi", category: String = "app", redactor: Redactor) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.redactor = redactor
    }

    public func info(_ message: String) {
        logger.info("\(redactor.redact(message), privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(redactor.redact(message), privacy: .public)")
    }
}

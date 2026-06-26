import Foundation

/// A non-printing wrapper around a sensitive string (API keys, tokens).
///
/// `description`/`debugDescription` always render as `***`, so a `Secret` can never leak
/// into logs or string interpolation by accident. The plaintext is only available by an
/// explicit `reveal()` call at the point of use.
public struct Secret: Sendable, Equatable {
    private let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    /// Returns the underlying plaintext. Call only at the point of use (e.g. building a
    /// request header) and never hold onto the result longer than necessary.
    public func reveal() -> String {
        raw
    }

    public var isEmpty: Bool {
        raw.isEmpty
    }
}

extension Secret: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "***" }
    public var debugDescription: String { "Secret(***)" }
}

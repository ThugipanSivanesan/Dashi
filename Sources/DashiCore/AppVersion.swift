import Foundation

/// Renders the running build's identity as a short label, or "dev" when no version is known.
public enum AppVersion {
    private static let devLabel = "dev"

    /// Formats "v1.2.3 (45)", "v1.2.3" when the build is blank, or "dev" when the version is blank.
    public static func label(shortVersion: String?, build: String?) -> String {
        guard let shortVersion = nonBlank(shortVersion) else { return devLabel }
        guard let build = nonBlank(build) else { return "v\(shortVersion)" }
        return "v\(shortVersion) (\(build))"
    }

    /// Formats the label from a bundle's `CFBundleShortVersionString` and `CFBundleVersion` keys.
    public static func label(bundle: Bundle = .main) -> String {
        label(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// Trims surrounding whitespace, mapping nil, empty and whitespace-only values alike to nil.
    private static func nonBlank(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

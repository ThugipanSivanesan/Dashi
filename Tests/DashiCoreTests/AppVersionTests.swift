import XCTest

@testable import DashiCore

/// One row of the formatter table: the two raw Info.plist values and the label they format to.
private struct LabelCase {
    let shortVersion: String?
    let build: String?
    let expected: String
}

final class AppVersionTests: XCTestCase {
    /// Writes an Info.plist into a throwaway `.bundle` directory and returns that bundle loaded.
    private func makeBundle(info: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appversion-\(UUID().uuidString)")
        let bundleURL = root.appendingPathComponent("Probe.bundle")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try XCTUnwrap(Bundle(path: bundleURL.path))
    }

    /// Appends the build only when it holds a non-blank value, and trims padding off both parts.
    func testLabelFormatsShortVersionAndBuild() {
        let cases = [
            LabelCase(shortVersion: "0.4.0", build: "8", expected: "v0.4.0 (8)"),
            LabelCase(shortVersion: "0.4.0", build: nil, expected: "v0.4.0"),
            LabelCase(shortVersion: "0.4.0", build: "", expected: "v0.4.0"),
            LabelCase(shortVersion: "0.4.0", build: "   ", expected: "v0.4.0"),
            LabelCase(shortVersion: nil, build: "8", expected: "dev"),
            LabelCase(shortVersion: "", build: "8", expected: "dev"),
            LabelCase(shortVersion: "   ", build: "8", expected: "dev"),
            LabelCase(shortVersion: "  0.4.0  ", build: "  8  ", expected: "v0.4.0 (8)"),
        ]
        for row in cases {
            XCTAssertEqual(
                AppVersion.label(shortVersion: row.shortVersion, build: row.build), row.expected,
                "short=\(String(describing: row.shortVersion)) "
                    + "build=\(String(describing: row.build))")
        }
    }

    /// Labels a run that knows neither a short version nor a build as exactly "dev".
    func testLabelWithoutShortVersionOrBuildIsDev() {
        XCTAssertEqual(AppVersion.label(shortVersion: nil, build: nil), "dev")
    }

    /// Resolves `CFBundleShortVersionString` and `CFBundleVersion` from a bundle's Info.plist.
    func testLabelReadsVersionKeysFromBundle() throws {
        let bundle = try makeBundle(info: [
            "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42",
        ])
        XCTAssertEqual(AppVersion.label(bundle: bundle), "v1.2.3 (42)")
    }

    /// Labels a bundle whose Info.plist carries neither version key as "dev".
    func testLabelFallsBackToDevForBundleWithoutVersionKeys() throws {
        let bundle = try makeBundle(info: ["CFBundleIdentifier": "com.example.probe"])
        XCTAssertEqual(AppVersion.label(bundle: bundle), "dev")
    }
}

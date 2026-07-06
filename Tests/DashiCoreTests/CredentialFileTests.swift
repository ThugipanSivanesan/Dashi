import XCTest

@testable import DashiCore

final class CredentialFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("credfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReadsRegularFile() throws {
        let file = dir.appendingPathComponent("auth.json")
        try Data("{}".utf8).write(to: file)
        XCTAssertEqual(CredentialFile.read(at: file), Data("{}".utf8))
    }

    func testReturnsNilForMissingFile() {
        XCTAssertNil(CredentialFile.read(at: dir.appendingPathComponent("nope.json")))
    }

    func testReturnsNilForDirectory() {
        XCTAssertNil(CredentialFile.read(at: dir))
    }

    func testReturnsNilForSymlink() throws {
        let target = dir.appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(CredentialFile.read(at: link))
    }

    func testReturnsNilForOversizedFile() throws {
        let file = dir.appendingPathComponent("big.json")
        try Data(count: CredentialFile.maxBytes + 1).write(to: file)
        XCTAssertNil(CredentialFile.read(at: file))
    }
}

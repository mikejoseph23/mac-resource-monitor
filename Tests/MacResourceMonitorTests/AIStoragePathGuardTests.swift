import XCTest
@testable import MacResourceMonitor

final class AIStoragePathGuardTests: XCTestCase {
    private let home = "/Users/mike"

    // MARK: - Accepts

    func testAcceptsLMStudioServerLog() {
        XCTAssertTrue(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio/server-logs/2026-08/x.log", homePath: home))
    }

    func testAcceptsOMLXLog() {
        XCTAssertTrue(AIStoragePathGuard.isReadable(
            path: "\(home)/.omlx/logs/server.log", homePath: home))
    }

    func testAcceptsNestedLMStudioConversation() {
        XCTAssertTrue(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio/conversations/a.json", homePath: home))
    }

    // MARK: - Denies paths outside both roots

    func testDeniesPathOutsideBothRoots() {
        XCTAssertFalse(AIStoragePathGuard.isReadable(path: "/tmp/x.log", homePath: home))
    }

    func testDeniesSiblingDirectory() {
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.other/server-logs/x.log", homePath: home))
    }

    func testDeniesPrefixTrapDirectory() {
        // `.lmstudio-evil` shares the `.lmstudio` prefix as a raw string but is
        // not the guarded directory — the guard must require a full path
        // segment match (trailing "/"), not a bare string prefix.
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio-evil/server-logs/x.log", homePath: home))
    }

    // MARK: - Denies never-touch paths and anything under them

    func testDeniesLMStudioModelsDirectlyAndNested() {
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio/models", homePath: home))
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio/models/some-model.gguf", homePath: home))
    }

    func testDeniesLMStudioInternalBundledModels() {
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio/.internal/bundled-models", homePath: home))
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.lmstudio/.internal/bundled-models/weights.bin", homePath: home))
    }

    func testDeniesOMLXBin() {
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.omlx/bin", homePath: home))
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.omlx/bin/server", homePath: home))
    }

    func testDeniesOMLXSettingsJSON() {
        XCTAssertFalse(AIStoragePathGuard.isReadable(
            path: "\(home)/.omlx/settings.json", homePath: home))
    }

    // MARK: - Denies the root dirs themselves

    func testDeniesLMStudioRootItself() {
        XCTAssertFalse(AIStoragePathGuard.isReadable(path: "\(home)/.lmstudio", homePath: home))
    }

    func testDeniesOMLXRootItself() {
        XCTAssertFalse(AIStoragePathGuard.isReadable(path: "\(home)/.omlx", homePath: home))
    }
}

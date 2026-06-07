import XCTest
@testable import Transcribr

final class RecordsDirectoryStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.transcribr.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_defaultDirectory_endsWithTranscribrUnderDocuments() {
        let url = RecordsDirectoryStore.defaultDirectory()
        XCTAssertEqual(url.lastPathComponent, "Transcribr")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Documents")
    }

    func test_init_withoutStoredValue_usesDefaultDirectory() {
        let store = RecordsDirectoryStore(defaults: defaults)
        XCTAssertEqual(
            store.directory.standardizedFileURL,
            RecordsDirectoryStore.defaultDirectory().standardizedFileURL
        )
    }

    func test_init_withStoredValue_readsStoredDirectory() {
        let path = NSTemporaryDirectory() + "transcribr-test-\(UUID().uuidString)"
        defaults.set(path, forKey: RecordsDirectoryStore.storageKey)

        let store = RecordsDirectoryStore(defaults: defaults)
        XCTAssertEqual(store.directory.path, URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    func test_update_persistsAndExposesDirectory() {
        let store = RecordsDirectoryStore(defaults: defaults)
        let newURL = URL(
            fileURLWithPath: NSTemporaryDirectory() + "transcribr-test-\(UUID().uuidString)",
            isDirectory: true
        )

        store.update(to: newURL)

        XCTAssertEqual(store.directory.standardizedFileURL, newURL.standardizedFileURL)
        XCTAssertEqual(
            defaults.string(forKey: RecordsDirectoryStore.storageKey),
            newURL.standardizedFileURL.path
        )
    }

    func test_update_thenReinit_restoresDirectory() {
        let first = RecordsDirectoryStore(defaults: defaults)
        let target = URL(
            fileURLWithPath: NSTemporaryDirectory() + "transcribr-test-\(UUID().uuidString)",
            isDirectory: true
        )
        first.update(to: target)

        let restored = RecordsDirectoryStore(defaults: defaults)
        XCTAssertEqual(restored.directory.standardizedFileURL, target.standardizedFileURL)
    }

    func test_ensureDirectoryExists_createsMissingDirectory() throws {
        let tempPath = NSTemporaryDirectory() + "transcribr-test-\(UUID().uuidString)"
        defaults.set(tempPath, forKey: RecordsDirectoryStore.storageKey)
        let store = RecordsDirectoryStore(defaults: defaults)

        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        try store.ensureDirectoryExists()

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempPath, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_ensureDirectoryExists_isIdempotent() throws {
        let tempPath = NSTemporaryDirectory() + "transcribr-test-\(UUID().uuidString)"
        defaults.set(tempPath, forKey: RecordsDirectoryStore.storageKey)
        let store = RecordsDirectoryStore(defaults: defaults)
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        try store.ensureDirectoryExists()
        XCTAssertNoThrow(try store.ensureDirectoryExists())
    }
}

/// Exercises the real login Keychain. Each test uses a unique `service` namespace and
/// removes its items in `tearDown`, so it never collides with other Keychain entries.
final class KeychainStoreTests: XCTestCase {
    private var service: String!
    private let account = "test.account"

    override func setUp() {
        super.setUp()
        service = "test.transcribr.keychain.\(UUID().uuidString)"
    }

    override func tearDown() {
        KeychainStore.delete(service: service, account: account)
        service = nil
        super.tearDown()
    }

    func test_setThenGet_roundTripsValue() {
        XCTAssertTrue(KeychainStore.set("sk-test-123", service: service, account: account))
        XCTAssertEqual(KeychainStore.get(service: service, account: account), "sk-test-123")
    }

    func test_set_overwritesExistingValue() {
        KeychainStore.set("old", service: service, account: account)
        KeychainStore.set("new", service: service, account: account)
        XCTAssertEqual(KeychainStore.get(service: service, account: account), "new")
    }

    func test_setEmptyString_deletesItem() {
        KeychainStore.set("value", service: service, account: account)
        XCTAssertTrue(KeychainStore.set("", service: service, account: account))
        XCTAssertNil(KeychainStore.get(service: service, account: account))
    }

    func test_get_missingItem_returnsNil() {
        XCTAssertNil(KeychainStore.get(service: service, account: account))
    }

    func test_delete_isIdempotent() {
        XCTAssertTrue(KeychainStore.delete(service: service, account: account))
        KeychainStore.set("value", service: service, account: account)
        XCTAssertTrue(KeychainStore.delete(service: service, account: account))
        XCTAssertTrue(KeychainStore.delete(service: service, account: account))
        XCTAssertNil(KeychainStore.get(service: service, account: account))
    }

    func test_unicodeValue_isPreservedExactly() {
        let value = "ключ-🔑-π"
        KeychainStore.set(value, service: service, account: account)
        XCTAssertEqual(KeychainStore.get(service: service, account: account), value)
    }
}


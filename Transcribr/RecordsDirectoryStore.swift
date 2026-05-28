import Foundation

final class RecordsDirectoryStore: ObservableObject {
    static let storageKey = "transcribr.recordsDirectoryPath"

    @Published private(set) var directory: URL

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let storedPath = defaults.string(forKey: Self.storageKey), !storedPath.isEmpty {
            self.directory = URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL
        } else {
            self.directory = Self.defaultDirectory()
        }
    }

    static func defaultDirectory() -> URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        return documents
            .appendingPathComponent("Transcribr", isDirectory: true)
            .standardizedFileURL
    }

    func update(to url: URL) {
        let normalized = url.standardizedFileURL
        directory = normalized
        defaults.set(normalized.path, forKey: Self.storageKey)
    }

    @discardableResult
    func ensureDirectoryExists() throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: directory.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}

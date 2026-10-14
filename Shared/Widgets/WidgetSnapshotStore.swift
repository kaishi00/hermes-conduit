import Foundation

struct WidgetSnapshotStore {
    static let appGroup = "group.com.milim.relay.launcher"
    static let filename = "launcher-v1.json"
    private let directory: URL
    private let fileManager: FileManager
    private let writeObserver: (() -> Void)?

    init(directory: URL, fileManager: FileManager = .default, writeObserver: (() -> Void)? = nil) {
        self.directory = directory
        self.fileManager = fileManager
        self.writeObserver = writeObserver
    }

    static var production: WidgetSnapshotStore? {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        return WidgetSnapshotStore(directory: directory)
    }

    func read() -> WidgetSnapshot? {
        let url = directory.appendingPathComponent(Self.filename)
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(WidgetSnapshot.self, from: data),
              value.schemaVersion == WidgetSnapshot.currentSchemaVersion else { return nil }
        return value
    }

    @discardableResult
    func write(_ snapshot: WidgetSnapshot) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let url = directory.appendingPathComponent(Self.filename)
        if let previous = try? Data(contentsOf: url), previous == data { return false }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        writeObserver?()
        return true
    }
}

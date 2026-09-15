import Foundation
import PlsInputCore

/// JSON 文件存档，放在 Application Support/PlsInput 下。
final class Store: Sendable {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlsInput", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    enum File: String {
        case today = "today.json"
        case stats = "stats.json"
        case configCache = "config-cache.json"
        case pendingSubmission = "pending-submit.json"
        case settings = "settings.json"
    }

    func load<T: Decodable>(_ type: T.Type, from file: File) -> T? {
        let url = directory.appendingPathComponent(file.rawValue)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, to file: File) {
        let url = directory.appendingPathComponent(file.rawValue)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func remove(_ file: File) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.rawValue))
    }
}

struct AppSettings: Codable, Hashable, Sendable {
    var hapticsEnabled = true
    var tutorialCompleted = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        tutorialCompleted = try c.decodeIfPresent(Bool.self, forKey: .tutorialCompleted) ?? false
    }
}

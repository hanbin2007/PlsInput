import Foundation
import PlsInputCore

/// 远程配置：只读 JSON，带本地缓存，失败时降级到内置默认。
final class ConfigService: Sendable {
    struct Cache: Codable, Sendable {
        var fetchedAt: Date
        var config: RemoteConfig
    }

    static let defaultURL = URL(string: "https://kn.origenclub.cn/plsinput/config.json")!

    private let url: URL
    private let store: Store
    private let session: URLSession
    private let minimumInterval: TimeInterval

    init(url: URL = ConfigService.defaultURL, store: Store, minimumInterval: TimeInterval = 3600) {
        self.url = url
        self.store = store
        self.minimumInterval = minimumInterval
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    /// 立即可用的配置：缓存优先，其次内置。
    func cached() -> RemoteConfig {
        store.load(Cache.self, from: .configCache)?.config ?? .builtIn
    }

    /// 距上次成功拉取不足间隔则直接返回缓存；否则拉取，失败返回缓存。
    func refresh(force: Bool = false) async -> RemoteConfig {
        let cache = store.load(Cache.self, from: .configCache)
        if !force, let cache, Date().timeIntervalSince(cache.fetchedAt) < minimumInterval {
            return cache.config
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return cache?.config ?? .builtIn
            }
            let config = try RemoteConfig.decode(data)
            store.save(Cache(fetchedAt: Date(), config: config), to: .configCache)
            return config
        } catch {
            return cache?.config ?? .builtIn
        }
    }
}

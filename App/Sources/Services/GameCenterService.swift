import Foundation
import GameKit
import Observation

/// Game Center：登录、提交分数、读榜。任务 6 补全实现。
@MainActor
@Observable
final class GameCenterService {
    struct Entry: Identifiable, Hashable, Sendable {
        var id: String
        var rank: Int
        var displayName: String
        var score: Int64
        var context: Int64
        var isLocalPlayer: Bool
    }

    struct Page: Sendable {
        var entries: [Entry]
        var localEntry: Entry?
        var totalCount: Int
    }

    enum Scope: Hashable, Sendable {
        case global
        case friends
    }

    private(set) var isAuthenticated = false
    private(set) var playerDisplayName: String?
    private(set) var lastError: String?

    /// 触发 Game Center 登录；系统需要时会自己弹出登录界面。
    func authenticate() {
        // 任务 6 实现：设置 GKLocalPlayer.local.authenticateHandler。
    }

    func submit(score: Int64, context: Int64, leaderboardIDs: [String]) async throws {
        // 任务 6 实现：GKLeaderboard.submitScore。
        throw GameCenterError.notImplemented
    }

    func loadEntries(leaderboardID: String, scope: Scope, range: Range<Int>) async throws -> Page {
        // 任务 6 实现：GKLeaderboard.loadEntries。
        throw GameCenterError.notImplemented
    }

    func loadLocalRank(leaderboardID: String) async throws -> Int? {
        throw GameCenterError.notImplemented
    }
}

enum GameCenterError: Error, Sendable {
    case notAuthenticated
    case notImplemented
}

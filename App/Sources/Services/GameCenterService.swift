import Foundation
import GameKit
import Observation
import UIKit

/// Game Center：登录、提交分数、读榜。
///
/// GameKit 的对象（`GKLocalPlayer`/`GKLeaderboard`/`GKLeaderboard.Entry`）都不是 `Sendable`，
/// 所以整个类锁在主线程上：SDK 里这些 async 方法都是 `nonisolated(nonsending)`，
/// 从 `@MainActor` 调用时不会跨隔离域，GameKit 对象自始至终留在主线程。
/// 对外只暴露 `Entry`/`Page` 这类纯值类型，跨域的只有它们。
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

        fileprivate var playerScope: GKLeaderboard.PlayerScope {
            switch self {
            case .global: return .global
            case .friends: return .friendsOnly
            }
        }
    }

    /// GameKit 一次最多返回 100 条，起始名次从 1 开始。
    private static let maxEntriesPerPage = 100

    private(set) var isAuthenticated = false
    private(set) var playerDisplayName: String?
    private(set) var lastError: String?

    /// GameKit 交回来的登录界面，用来避免重复 present。
    private weak var authViewController: UIViewController?

    // MARK: - 登录

    /// 触发 Game Center 登录；系统需要时会自己弹出登录界面。
    func authenticate() {
        // 排行榜是自绘的，不需要系统那个悬浮入口。
        GKAccessPoint.shared.isActive = false

        let local = GKLocalPlayer.local
        if local.isAuthenticated {
            // 已经登录，重复调用只同步一次状态。
            markAuthenticated(local)
            return
        }
        // 重新赋值 authenticateHandler 会让 GameKit 再跑一遍认证流程，
        // 所以上一次失败或取消之后再点“登录”仍然能把系统面板拉起来。
        installAuthenticateHandler()
    }

    private func installAuthenticateHandler() {
        // 闭包显式标成 @Sendable：GameCenterService 绑定在 MainActor 上，本身就是 Sendable，
        // 弱引用捕获安全；GameKit 保证在主线程回调，这里用 assumeIsolated 回到隔离域。
        GKLocalPlayer.local.authenticateHandler = { @Sendable [weak self] viewController, error in
            MainActor.assumeIsolated {
                self?.handleAuthentication(viewController: viewController, error: error)
            }
        }
    }

    private func handleAuthentication(viewController: UIViewController?, error: Error?) {
        if let viewController {
            presentAuthentication(viewController)
            return
        }
        let local = GKLocalPlayer.local
        if local.isAuthenticated {
            markAuthenticated(local)
        } else {
            isAuthenticated = false
            playerDisplayName = nil
            // GameKit 给的 message 已经本地化过；没有 error 就不打扰用户，界面本来就显示“未登录”。
            lastError = error?.localizedDescription
        }
    }

    private func markAuthenticated(_ player: GKLocalPlayer) {
        isAuthenticated = true
        playerDisplayName = player.displayName
        lastError = nil
    }

    private func presentAuthentication(_ viewController: UIViewController) {
        // GameKit 可能重复交回登录界面；已经在屏幕上就不再 present 一次。
        if let existing = authViewController, existing.presentingViewController != nil { return }
        guard let presenter = Self.topViewController() else { return }
        authViewController = viewController
        presenter.present(viewController, animated: true)
    }

    /// 前台窗口最上层的控制器，用来承载系统登录界面。
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return nil
        }
        let window = scene.keyWindow ?? scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    // MARK: - 提交

    func submit(score: Int64, context: Int64, leaderboardIDs: [String]) async throws {
        let local = GKLocalPlayer.local
        guard local.isAuthenticated else { throw GameCenterError.notAuthenticated }
        guard !leaderboardIDs.isEmpty else { return }
        try await GKLeaderboard.submitScore(
            Int(clamping: score),
            // context 存的是尾数的原始位模式，只能按位搬运，不能做数值转换。
            context: Int(truncatingIfNeeded: context),
            player: local,
            leaderboardIDs: leaderboardIDs
        )
    }

    // MARK: - 读榜

    func loadEntries(leaderboardID: String, scope: Scope, range: Range<Int>) async throws -> Page {
        guard GKLocalPlayer.local.isAuthenticated else { throw GameCenterError.notAuthenticated }
        guard let nsRange = Self.gameKitRange(from: range) else {
            return Page(entries: [], localEntry: nil, totalCount: 0)
        }
        let leaderboard = try await Self.leaderboard(id: leaderboardID)
        // 周期榜这里拿到的是当前这一期，正是我们要的。
        let (localPlayerEntry, rawEntries, totalCount) = try await leaderboard.loadEntries(
            for: scope.playerScope,
            timeScope: .allTime,
            range: nsRange
        )
        let localPlayerID = GKLocalPlayer.local.gamePlayerID
        let entries = rawEntries
            .map { Self.entry(from: $0, localPlayerID: localPlayerID) }
            .sorted { $0.rank < $1.rank }
        return Page(
            entries: entries,
            localEntry: localPlayerEntry.map { Self.entry(from: $0, localPlayerID: localPlayerID) },
            totalCount: totalCount
        )
    }

    func loadLocalRank(leaderboardID: String) async throws -> Int? {
        guard GKLocalPlayer.local.isAuthenticated else { throw GameCenterError.notAuthenticated }
        let leaderboard = try await Self.leaderboard(id: leaderboardID)
        // 只要本人那条，榜单本身取第 1 名一条最省流量。
        let (localPlayerEntry, _, _) = try await leaderboard.loadEntries(
            for: .global,
            timeScope: .allTime,
            range: NSRange(location: 1, length: 1)
        )
        return localPlayerEntry?.rank
    }

    // MARK: - 工具

    private static func leaderboard(id: String) async throws -> GKLeaderboard {
        let leaderboards = try await GKLeaderboard.loadLeaderboards(IDs: [id])
        guard let match = leaderboards.first(where: { $0.baseLeaderboardID == id }) ?? leaderboards.first else {
            throw GameCenterError.leaderboardNotFound(id)
        }
        return match
    }

    private static func entry(from raw: GKLeaderboard.Entry, localPlayerID: String) -> Entry {
        let player = raw.player
        let gamePlayerID = player.gamePlayerID
        var id = gamePlayerID
        if id.isEmpty { id = player.teamPlayerID }
        if id.isEmpty { id = "rank-\(raw.rank)" }
        return Entry(
            id: id,
            rank: raw.rank,
            displayName: player.displayName,
            score: Int64(raw.score),
            // 与提交时一样按位搬运，交给 ScoreCodec 还原。
            context: Int64(truncatingIfNeeded: raw.context),
            isLocalPlayer: !gamePlayerID.isEmpty && gamePlayerID == localPlayerID
        )
    }

    /// `Range<Int>` 是 0 起、左闭右开；GameKit 要求 location ≥ 1、length ≤ 100。
    private static func gameKitRange(from range: Range<Int>) -> NSRange? {
        let lower = max(0, range.lowerBound)
        let upper = max(lower, range.upperBound)
        let length = min(upper - lower, maxEntriesPerPage)
        guard length > 0 else { return nil }
        return NSRange(location: lower + 1, length: length)
    }
}

enum GameCenterError: Error, Sendable {
    case notAuthenticated
    case notImplemented
    case leaderboardNotFound(String)
}

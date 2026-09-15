import Foundation
import Observation
import PlsInputCore

/// 应用级状态：配置、存档、当天题、进行中的对局。
@MainActor
@Observable
final class AppModel {
    let store: Store
    let configService: ConfigService
    let gameCenter: GameCenterService

    private(set) var config: RemoteConfig
    var settings: AppSettings {
        didSet { store.save(settings, to: .settings) }
    }
    private(set) var stats: Stats
    private(set) var today: DayRecord?
    private(set) var isBootstrapped = false

    /// 正在展示的对局。
    var activeGame: GameViewModel?
    /// 教程进行中时的引导控制器。
    var activeTutorial: TutorialController?

    init(store: Store = Store()) {
        self.store = store
        configService = ConfigService(store: store)
        gameCenter = GameCenterService()
        config = configService.cached()
        settings = store.load(AppSettings.self, from: .settings) ?? AppSettings()
        stats = store.load(Stats.self, from: .stats) ?? Stats()
        today = store.load(DayRecord.self, from: .today)
    }

    // MARK: - 派生

    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = PuzzleCalendar.timeZone
        return c
    }

    var currentDay: String { PuzzleCalendar.dayString(for: Date()) }

    var resolver: ConfigResolver { ConfigResolver(config) }

    var requiresUpdate: Bool { resolver.requiresUpdate(appBuild: AppBuild.number) }

    var notice: String? { resolver.notice(preferredLanguages: Locale.preferredLanguages) }

    var streak: Int {
        let day = currentDay
        if stats.history[day] != nil {
            return stats.streak(endingOn: day, calendar: calendar)
        }
        guard let date = Stats.date(from: day, calendar: calendar),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: date) else { return 0 }
        return stats.streak(endingOn: Stats.string(from: yesterday, calendar: calendar), calendar: calendar)
    }

    // MARK: - 启动

    func bootstrap() async {
        rollDayIfNeeded()
        gameCenter.authenticate()
        config = await configService.refresh()
        rollDayIfNeeded()
        await retryPendingSubmission()
        isBootstrapped = true
    }

    /// 跨天后清掉旧记录。
    func rollDayIfNeeded() {
        if let today, today.day != currentDay {
            self.today = nil
            store.remove(.today)
        }
    }

    // MARK: - 每日模式

    /// 当天的题：已固化则直接用，否则生成并固化。
    func ensureTodayRecord() -> DayRecord {
        rollDayIfNeeded()
        if let today { return today }
        let day = currentDay
        let seed = PuzzleSeed.daily(day: day, salt: resolver.seedSalt(for: day))
        let puzzle = PuzzleGenerator.generate(seed: seed, balance: resolver.balance(for: day))
        let record = DayRecord(day: day, puzzle: puzzle)
        today = record
        store.save(record, to: .today)
        return record
    }

    func startDaily() {
        var record = ensureTodayRecord()
        guard record.result == nil else { return }
        let state = record.run ?? RunState(puzzle: record.puzzle)
        if record.run == nil {
            record.run = state
            today = record
            store.save(record, to: .today)
        }
        let model = GameViewModel(mode: .daily, state: state)
        model.hapticsEnabled = settings.hapticsEnabled
        model.onPersist = { [weak self] state in
            self?.persistDailyRun(state)
        }
        model.onEnded = { [weak self] state in
            self?.finishDaily(state)
        }
        activeGame = model
    }

    private func persistDailyRun(_ state: RunState) {
        guard var record = today, record.result == nil else { return }
        record.run = state
        today = record
        store.save(record, to: .today)
    }

    private func finishDaily(_ state: RunState) {
        guard var record = today, record.result == nil else { return }
        let result = RunResult(state: state)
        record.run = nil
        record.result = result
        today = record
        store.save(record, to: .today)
        stats.history[record.day] = result
        store.save(stats, to: .stats)
        Task { await submit(result: result, day: record.day) }
    }

    private func submit(result: RunResult, day: String) async {
        do {
            try await gameCenter.submit(score: result.score, context: result.context, leaderboardIDs: [LeaderboardID.daily, LeaderboardID.allTime])
            store.remove(.pendingSubmission)
            if var record = today, record.day == day {
                record.submitted = true
                record.rank = try? await gameCenter.loadLocalRank(leaderboardID: LeaderboardID.daily)
                today = record
                store.save(record, to: .today)
            }
        } catch {
            store.save(PendingSubmission(day: day, score: result.score, context: result.context), to: .pendingSubmission)
        }
    }

    private func retryPendingSubmission() async {
        guard let pending = store.load(PendingSubmission.self, from: .pendingSubmission) else { return }
        guard let result = stats.history[pending.day] else {
            store.remove(.pendingSubmission)
            return
        }
        await submit(result: result, day: pending.day)
    }

    // MARK: - 练习模式

    func startPractice(seed fixedSeed: String? = nil) {
        var rng = SystemRandomNumberGenerator()
        let seed = fixedSeed ?? PuzzleSeed.practice(using: &rng)
        let puzzle = PuzzleGenerator.generate(seed: seed, balance: resolver.balance(for: currentDay))
        let model = GameViewModel(mode: .practice, state: RunState(puzzle: puzzle))
        model.hapticsEnabled = settings.hapticsEnabled
        model.onEnded = { [weak self] state in
            self?.finishPractice(state)
        }
        activeGame = model
    }

    private func finishPractice(_ state: RunState) {
        stats.practiceRuns += 1
        if let best = stats.practiceBest, best >= state.peak {
            // 保持原纪录
        } else {
            stats.practiceBest = state.peak
        }
        store.save(stats, to: .stats)
    }

    func dismissGame() {
        activeGame?.pause()
        activeGame = nil
        activeTutorial = nil
    }

    // MARK: - 教程

    func startTutorial() {
        let model = GameViewModel(mode: .tutorial, state: RunState(puzzle: TutorialPuzzle.make()))
        model.hapticsEnabled = settings.hapticsEnabled
        activeTutorial = TutorialController(game: model)
        activeGame = model
    }

    func completeTutorial() {
        settings.tutorialCompleted = true
        dismissGame()
    }
}

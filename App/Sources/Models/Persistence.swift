import Foundation
import PlsInputCore

/// 一局的结果。
struct RunResult: Codable, Hashable, Sendable {
    var peak: BigNum
    var endReason: EndReason
    var rotClock: Double
    var tiersCrossed: Int
    var endedAt: Date
    var score: Int64
    var context: Int64

    init(state: RunState, endedAt: Date = Date()) {
        peak = state.peak
        if case .ended(let reason) = state.phase {
            endReason = reason
        } else {
            endReason = .playerEnded
        }
        rotClock = state.rotClock
        tiersCrossed = state.crossedTiers
        self.endedAt = endedAt
        let encoded = ScoreCodec.encode(state.peak)
        score = encoded.score
        context = encoded.context
    }
}

/// 当天的题、进行中的对局和结果。首次进入当天时固化。
struct DayRecord: Codable, Hashable, Sendable {
    var day: String
    var puzzle: DailyPuzzle
    var run: RunState?
    var result: RunResult?
    var submitted: Bool = false
    var rank: Int?

    var isFinished: Bool { result != nil }
    var isInProgress: Bool { run != nil && result == nil }
}

/// 历史与连胜。
struct Stats: Codable, Hashable, Sendable {
    var history: [String: RunResult] = [:]
    var practiceBest: BigNum?
    var practiceRuns: Int = 0

    /// 以某天为终点的连续游玩天数。
    func streak(endingOn day: String, calendar: Calendar) -> Int {
        guard var date = Stats.date(from: day, calendar: calendar) else { return 0 }
        var count = 0
        while history[Stats.string(from: date, calendar: calendar)] != nil {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }

    static func date(from day: String, calendar: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return calendar.date(from: components)
    }

    static func string(from date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// 提交失败后留待重试的分数。
struct PendingSubmission: Codable, Hashable, Sendable {
    var day: String
    var score: Int64
    var context: Int64
}

enum LeaderboardID {
    static let daily = "cn.origenclub.plsinput.daily"
    static let allTime = "cn.origenclub.plsinput.alltime"
}

enum AppBuild {
    static var number: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 1
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

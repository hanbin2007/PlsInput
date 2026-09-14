import Foundation
import Testing
@testable import PlsInputCore

@Suite("GreedyBot")
struct BotTests {
    // MARK: - 工具

    /// 一道好打的题：9 和 ^ 管够，5 个普通格，两档阈值。
    private func easyPuzzle() -> DailyPuzzle {
        DailyPuzzle(
            seed: "bot-easy",
            slots: [.normal, .normal, .normal, .normal, .normal],
            keys: [KeyDef(.digit(9), uses: 40), KeyDef(.pow, uses: 40)],
            rotInterval: 3,
            thresholds: [BigNum(threshold: "1e3")!, BigNum(threshold: "1e6")!],
            rewards: [.repair(amount: 8), .freeze(seconds: 10)],
            runCapSeconds: 60
        )
    }

    // MARK: - 确定性

    @Test func samePuzzleGivesIdenticalReports() {
        let puzzle = PuzzleGenerator.generate(seed: "PlsInput-v1-2026-09-15")
        let first = GreedyBot.play(puzzle: puzzle)
        let second = GreedyBot.play(puzzle: puzzle)
        #expect(first == second)
    }

    @Test func deterministicAcrossManySeeds() {
        for index in 0..<8 {
            let puzzle = PuzzleGenerator.generate(seed: "PlsInput-random-\(index)")
            #expect(GreedyBot.play(puzzle: puzzle) == GreedyBot.play(puzzle: puzzle))
        }
    }

    @Test func traceDoesNotChangeTheOutcome() {
        let puzzle = PuzzleGenerator.generate(seed: "PlsInput-v1-2026-10-01")
        var entries: [BotTraceEntry] = []
        let traced = GreedyBot.play(puzzle: puzzle) { entries.append($0) }
        #expect(traced == GreedyBot.play(puzzle: puzzle))
        #expect(!entries.isEmpty)
        // 轨迹的腐烂时钟单调不减。
        for index in 1..<entries.count {
            #expect(entries[index].rotClock >= entries[index - 1].rotClock)
        }
    }

    // MARK: - 好打的题

    @Test func easyPuzzleBuildsATower() {
        let report = GreedyBot.play(puzzle: easyPuzzle())
        // 9^9^9 已经进了第 1 层。
        #expect(report.peak.layer >= 1)
        #expect(report.peak >= BigNum(9).power(BigNum(9).power(BigNum(9))))
        #expect(report.tiersCrossed == 2)
        #expect(report.tierTimes.count == 2)
        #expect(report.presses > 0)
        #expect(report.runSeconds <= 60)
        #expect(report.slotKindsAtEnd.count == 5)
        #expect(report.keysAtEnd == ["9", "^"])
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let report = GreedyBot.play(puzzle: easyPuzzle())
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(BotReport.self, from: data)
        #expect(decoded == report)
    }

    // MARK: - 生成的题

    @Test func generatedPuzzleMakesProgress() {
        let puzzle = PuzzleGenerator.generate(seed: "PlsInput-v1-2026-09-15")
        let report = GreedyBot.play(puzzle: puzzle)
        #expect(report.tiersCrossed >= 1)
        #expect(report.presses > 0)
        #expect(report.peakSlog > 0)
        #expect(report.tierTimes.count == report.tiersCrossed)
        #expect(report.runSeconds <= puzzle.runCapSeconds)
    }

    @Test func everySeedTerminatesAndStaysConsistent() {
        for index in 0..<30 {
            let puzzle = PuzzleGenerator.generate(seed: "PlsInput-bot-\(index)")
            let report = GreedyBot.play(puzzle: puzzle)
            #expect(report.seed == puzzle.seed)
            #expect(report.runSeconds <= puzzle.runCapSeconds)
            #expect(report.tierTimes.count == report.tiersCrossed)
            #expect(report.tiersCrossed <= puzzle.thresholds.count)
            #expect(report.slotKindsAtEnd.count >= puzzle.slots.count)
            #expect(report.presses >= 0)
        }
    }

    // MARK: - 速度

    @Test func thirtySeedsFinishQuickly() {
        let started = Date()
        for index in 0..<30 {
            _ = GreedyBot.play(puzzle: PuzzleGenerator.generate(seed: "PlsInput-speed-\(index)"))
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 10, "30 个种子用了 \(elapsed) 秒")
    }

    // MARK: - 规划器

    @Test func plannerPrefersTowerOverConcatenation() {
        let input = PlanInput(
            kinds: [.normal, .normal, .normal, .normal, .normal],
            current: [SlotFill](repeating: .empty, count: 5),
            symbols: [.digit(9), .pow],
            uses: [.digit(9): 20, .pow: 20]
        )
        var rng = SplitMix64(seed: 1)
        let planned = BotPlanner.plan(input, iterations: 400, seed: nil, using: &rng)
        #expect(planned.value != nil)
        #expect((planned.value ?? .zero) >= BigNum(9).power(BigNum(9).power(BigNum(9))))
    }

    @Test func plannerRespectsDurability() {
        // 9 只剩 1 点耐久，布局里最多出现一次。
        let input = PlanInput(
            kinds: [.normal, .normal, .normal],
            current: [SlotFill](repeating: .empty, count: 3),
            symbols: [.digit(9), .pow],
            uses: [.digit(9): 1, .pow: 5]
        )
        var rng = SplitMix64(seed: 2)
        let planned = BotPlanner.plan(input, iterations: 300, seed: nil, using: &rng)
        let nines = planned.layout.filter { $0 == .key(.digit(9)) }.count
        #expect(nines <= 1)
        #expect(BotPlanner.isFeasible(input, planned.layout))
    }

    @Test func plannerMatchesEngineTokenDerivation() {
        // 回声与增幅的推导必须和 RunState.effectiveToken 一致。
        let kinds: [SlotKind] = [.normal, .amp, .echo, .normal, .echo]
        let layout: [SlotFill] = [.key(.digit(9)), .key(.digit(9)), .empty, .key(.pow), .empty]
        let input = PlanInput(
            kinds: kinds,
            current: [SlotFill](repeating: .empty, count: kinds.count),
            symbols: [.digit(9), .pow],
            uses: [.digit(9): 9, .pow: 9]
        )
        let puzzle = DailyPuzzle(
            seed: "echo",
            slots: kinds,
            keys: [KeyDef(.digit(9), uses: 9), KeyDef(.pow, uses: 9)],
            rotInterval: 100,
            thresholds: [],
            rewards: [],
            runCapSeconds: 300
        )
        var state = RunState(puzzle: puzzle)
        state.slots[0].content = .digit(base: 9, placedAt: 0)
        state.slots[1].content = .digit(base: 9, placedAt: 0)
        state.slots[3].content = .op(.pow)
        #expect(BotPlanner.value(input, layout) == state.evaluate())
    }

    @Test func plannerCountsRottenSlotsAsFree() {
        let input = PlanInput(
            kinds: [.rotten, .rotten, .rotten],
            current: [SlotFill](repeating: .empty, count: 3),
            symbols: [.digit(9)],
            uses: [.digit(9): 1]
        )
        let layout: [SlotFill] = [.key(.digit(9)), .key(.digit(9)), .key(.digit(9))]
        #expect(BotPlanner.pressCount(input, layout) == 0)
        #expect(BotPlanner.isFeasible(input, layout))

        // 键报废之后连烂格也填不了。
        var dead = input
        dead.uses = [.digit(9): 0]
        #expect(!BotPlanner.isFeasible(dead, layout))
    }

    // MARK: - 结束条件

    @Test func botEndsWhenNothingIsLeftToDo() {
        // 只有一个数字键、一格，按完即报废，引擎自己结束。
        let puzzle = DailyPuzzle(
            seed: "bot-tiny",
            slots: [.normal],
            keys: [KeyDef(.digit(9), uses: 1), KeyDef(.digit(8), uses: 1)],
            rotInterval: 3,
            thresholds: [],
            rewards: [],
            runCapSeconds: 60
        )
        let report = GreedyBot.play(puzzle: puzzle)
        #expect(report.endReason == .keysExhausted || report.endReason == .playerEnded)
        #expect(report.runSeconds < 60)
        #expect(report.peak == BigNum(9))
    }

    @Test func slowerIntervalMeansFewerDecisions() {
        let puzzle = easyPuzzle()
        let fast = GreedyBot.play(puzzle: puzzle, config: BotConfig(decisionInterval: 0.2))
        let slow = GreedyBot.play(puzzle: puzzle, config: BotConfig(decisionInterval: 1.5))
        #expect(fast.presses >= slow.presses)
    }
}

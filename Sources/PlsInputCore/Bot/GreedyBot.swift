import Foundation

// MARK: - 对外类型

/// 机器人的运行参数。
public struct BotConfig: Sendable, Hashable {
    /// 两次决策之间推进的真实时间（秒），用来模拟人的操作速度。
    public var decisionInterval: Double
    /// 规划布局时随机爬山的迭代次数。
    public var searchIterations: Int

    public init(decisionInterval: Double = 0.35, searchIterations: Int = 400) {
        self.decisionInterval = decisionInterval
        self.searchIterations = searchIterations
    }
}

/// 一局机器人对局的结果，校准脚本的统计单元。
public struct BotReport: Sendable, Codable, Hashable {
    public var seed: String
    public var peak: BigNum
    public var peakSlog: Double
    public var tiersCrossed: Int
    /// 每次跨档时的腐烂时钟（秒），按档位顺序。
    public var tierTimes: [Double]
    public var presses: Int
    public var endReason: EndReason
    /// 结束时的腐烂时钟（秒）。
    public var runSeconds: Double
    public var slotKindsAtEnd: [SlotKind]
    /// 结束时键盘上的键，取符号的显示文本。
    public var keysAtEnd: [String]

    public init(
        seed: String,
        peak: BigNum,
        peakSlog: Double,
        tiersCrossed: Int,
        tierTimes: [Double],
        presses: Int,
        endReason: EndReason,
        runSeconds: Double,
        slotKindsAtEnd: [SlotKind],
        keysAtEnd: [String]
    ) {
        self.seed = seed
        self.peak = peak
        self.peakSlog = peakSlog
        self.tiersCrossed = tiersCrossed
        self.tierTimes = tierTimes
        self.presses = presses
        self.endReason = endReason
        self.runSeconds = runSeconds
        self.slotKindsAtEnd = slotKindsAtEnd
        self.keysAtEnd = keysAtEnd
    }
}

/// 逐决策的调试轨迹，`plsbot --seed` 用它打印一局的全过程。
public struct BotTraceEntry: Sendable, Hashable {
    public var rotClock: Double
    public var action: String
    public var value: BigNum?

    public init(rotClock: Double, action: String, value: BigNum?) {
        self.rotClock = rotClock
        self.action = action
        self.value = value
    }
}

/// 贪心校准机器人。
///
/// 不追求最优解，只求做一个称职人类玩家的代理：先规划一个"用当前键盘能拼出的最大值"的
/// 目标布局，按顺序填出来，然后不断把腐烂掉的数字救回去，跨档时按"哪种选择规划出的值更大"
/// 挑选项。同一道题必得到同一份报告，随机性只来自 `SplitMix64(seed:)`。
public enum GreedyBot {
    public static func play(puzzle: DailyPuzzle, config: BotConfig = BotConfig()) -> BotReport {
        var player = BotPlayer(puzzle: puzzle, config: config)
        return player.run(trace: nil)
    }

    /// 带轨迹的版本，行为与不带轨迹的完全一致。
    public static func play(
        puzzle: DailyPuzzle,
        config: BotConfig = BotConfig(),
        trace: @escaping (BotTraceEntry) -> Void
    ) -> BotReport {
        var player = BotPlayer(puzzle: puzzle, config: config)
        return player.run(trace: trace)
    }
}

// MARK: - 布局

/// 目标布局里一个格子的内容。
enum SlotFill: Hashable, Sendable {
    case empty
    case key(KeySymbol)
    /// 保留格子里现有的数字，对应的键已经报废、按不回来了，所以只值当前腐烂后的这个数。
    /// 规划时它不要钱也换不来，只能原样留着或者清空。
    case frozen(Int)
}

/// 规划一次布局需要的全部输入。全部是数组和只做查表的字典，
/// 任何影响结果的遍历都走数组，避免字典遍历顺序破坏确定性。
struct PlanInput: Sendable {
    /// 每格的类型。
    var kinds: [SlotKind]
    /// 每格当前的内容；回声格恒为 `.empty`。目标与它相同的格子不需要按键。
    var current: [SlotFill]
    /// 键盘上的键，顺序固定。
    var symbols: [KeySymbol]
    /// 每个键的剩余耐久，报废为 0。只查表，不遍历。
    var uses: [KeySymbol: Int]

    func remaining(_ symbol: KeySymbol) -> Int { uses[symbol] ?? 0 }

    var aliveSymbols: [KeySymbol] { symbols.filter { remaining($0) > 0 } }
}

// MARK: - 规划器

/// 布局搜索：模板打底 + 随机单格变异爬山。
enum BotPlanner {
    /// 0…18 的字符串常量，增幅格的 9 会变成 "18"。避开求值热路径上的字符串构造。
    static let digitStrings: [String] = (0...18).map { String($0) }

    // MARK: 求值

    /// 假想布局里某格的有效词元，规则与 `RunState.effectiveToken` 一致（数字一律视为新鲜）。
    static func token(_ input: PlanInput, _ layout: [SlotFill], at index: Int, depth: Int = 0) -> Token? {
        guard depth < 64, input.kinds.indices.contains(index) else { return nil }
        if input.kinds[index] == .echo {
            let source = index - 2
            guard source >= 0 else { return nil }
            return token(input, layout, at: source, depth: depth + 1)
        }
        switch layout[index] {
        case .empty:
            return nil
        case .frozen(let value):
            return number(value, amplified: input.kinds[index] == .amp)
        case .key(let symbol):
            if case .digit(let d) = symbol {
                return number(d, amplified: input.kinds[index] == .amp)
            }
            return Token(symbol: symbol)
        }
    }

    private static func number(_ digit: Int, amplified: Bool) -> Token {
        let effective = amplified ? digit * 2 : digit
        guard digitStrings.indices.contains(effective) else { return .number(String(effective)) }
        return .number(digitStrings[effective])
    }

    static func value(_ input: PlanInput, _ layout: [SlotFill]) -> BigNum? {
        var tokens: [Token] = []
        tokens.reserveCapacity(input.kinds.count)
        for index in input.kinds.indices {
            if let t = token(input, layout, at: index) { tokens.append(t) }
        }
        return Expression.evaluate(tokens)
    }

    // MARK: 代价与可行性

    /// 把目标布局摆出来还要按多少次键。已经摆好的、清空的、烂格里的都不要钱。
    static func pressCost(_ input: PlanInput, _ layout: [SlotFill], at index: Int) -> Int {
        guard input.kinds[index] != .echo else { return 0 }
        guard case .key = layout[index] else { return 0 }
        if layout[index] == input.current[index] { return 0 }
        return input.kinds[index] == .rotten ? 0 : 1
    }

    static func pressCount(_ input: PlanInput, _ layout: [SlotFill]) -> Int {
        var total = 0
        for index in input.kinds.indices { total += pressCost(input, layout, at: index) }
        return total
    }

    /// 需要按的键必须还活着，而且按的次数不能超过剩余耐久。
    static func isFeasible(_ input: PlanInput, _ layout: [SlotFill]) -> Bool {
        var used: [KeySymbol: Int] = [:]
        for index in input.kinds.indices {
            guard input.kinds[index] != .echo else { continue }
            // 冻结内容只能待在它自己的格子里，变不出来。
            if case .frozen = layout[index] {
                guard layout[index] == input.current[index] else { return false }
                continue
            }
            guard case .key(let symbol) = layout[index] else { continue }
            if layout[index] == input.current[index] { continue }
            let cap = input.remaining(symbol)
            guard cap > 0 else { return false }
            // 烂格免耗，但键仍然必须活着。
            if input.kinds[index] == .rotten { continue }
            let next = (used[symbol] ?? 0) + 1
            if next > cap { return false }
            used[symbol] = next
        }
        return true
    }

    /// 把超预算的格子逐个清空，使任意模板都落回可行域。
    static func truncate(_ input: PlanInput, _ layout: [SlotFill]) -> [SlotFill] {
        var used: [KeySymbol: Int] = [:]
        var out = layout
        for index in input.kinds.indices {
            if input.kinds[index] == .echo {
                out[index] = .empty
                continue
            }
            // 冻结内容一律归位成这格现有的东西。
            if case .frozen = out[index] {
                out[index] = input.current[index]
                continue
            }
            guard case .key(let symbol) = out[index] else { continue }
            if out[index] == input.current[index] { continue }
            let cap = input.remaining(symbol)
            if cap <= 0 {
                out[index] = .empty
                continue
            }
            if input.kinds[index] == .rotten { continue }
            let next = (used[symbol] ?? 0) + 1
            if next > cap {
                out[index] = .empty
                continue
            }
            used[symbol] = next
        }
        return out
    }

    // MARK: 模板

    /// 候选起点：拼接、幂塔、阶乘链、`(d…)!`、以及缺 `^`/`!` 时的 `×`/`+` 串。
    static func templates(_ input: PlanInput) -> [[SlotFill]] {
        let positions = input.kinds.indices.filter { input.kinds[$0] != .echo }
        guard !positions.isEmpty else { return [] }
        let width = positions.count
        var out: [[SlotFill]] = []

        func emit(_ pattern: (Int) -> SlotFill) {
            var layout = [SlotFill](repeating: .empty, count: input.kinds.count)
            for (offset, index) in positions.enumerated() { layout[index] = pattern(offset) }
            out.append(layout)
        }

        let hasPow = input.remaining(.pow) > 0
        let hasFactorial = input.remaining(.factorial) > 0
        let hasParen = input.remaining(.lparen) > 0 && input.remaining(.rparen) > 0
        let hasTimes = input.remaining(.times) > 0
        let hasPlus = input.remaining(.plus) > 0

        let digits = input.aliveSymbols.filter(\.isDigit)
        for digit in digits {
            let d = SlotFill.key(digit)
            let pow = SlotFill.key(.pow)
            let fact = SlotFill.key(.factorial)

            // 全数字拼接。
            emit { _ in d }

            if hasPow {
                // 幂塔 d^d^d…
                emit { $0 % 2 == 0 ? d : pow }
                if width >= 2 {
                    // 拼接 ^ 拼接，例如 99^99。
                    for split in 1..<width { emit { $0 == split ? pow : d } }
                }
            }
            if hasFactorial {
                // d!!!…
                emit { $0 == 0 ? d : fact }
                if width >= 2 {
                    // ddd!!
                    for split in 1..<width { emit { $0 < split ? d : fact } }
                    // 幂塔接阶乘尾巴。
                    if hasPow {
                        for split in 1..<width {
                            emit { $0 < split ? ($0 % 2 == 0 ? d : pow) : fact }
                        }
                    }
                }
            }
            if hasParen, width >= 3 {
                // ( d… ) 后面接阶乘（没有阶乘就只留括号组）。
                for close in 2..<width {
                    emit { offset in
                        if offset == 0 { return .key(.lparen) }
                        if offset < close { return d }
                        if offset == close { return .key(.rparen) }
                        return hasFactorial ? fact : .empty
                    }
                }
            }
            if hasTimes { emit { $0 % 2 == 0 ? d : .key(.times) } }
            if hasPlus { emit { $0 % 2 == 0 ? d : .key(.plus) } }
        }
        return out
    }

    // MARK: 搜索

    /// 布局评分：值优先，值相同取按键少的。
    static func isBetter(_ lhs: (value: BigNum?, presses: Int), than rhs: (value: BigNum?, presses: Int)) -> Bool {
        switch (lhs.value, rhs.value) {
        case (nil, _):
            return false
        case (.some, nil):
            return true
        case (.some(let a), .some(let b)):
            if a != b { return a > b }
            return lhs.presses < rhs.presses
        }
    }

    /// 模板打底，再做 `iterations` 次随机单格变异，保留改进。
    static func plan(
        _ input: PlanInput,
        iterations: Int,
        seed: [SlotFill]?,
        using rng: inout SplitMix64
    ) -> (layout: [SlotFill], value: BigNum?) {
        let count = input.kinds.count
        var best = [SlotFill](repeating: .empty, count: count)
        var bestScore: (value: BigNum?, presses: Int) = (value(input, best), 0)

        func consider(_ candidate: [SlotFill]) {
            guard candidate.count == count else { return }
            let layout = truncate(input, candidate)
            let score = (value: value(input, layout), presses: pressCount(input, layout))
            if isBetter(score, than: bestScore) {
                best = layout
                bestScore = score
            }
        }

        // 保持现状与上一轮计划都是候选起点，避免每次重规划都把已经摆好的布局推倒重来。
        consider(input.current)
        if let seed { consider(seed) }
        for template in templates(input) { consider(template) }

        let positions = input.kinds.indices.filter { input.kinds[$0] != .echo }
        guard !positions.isEmpty, iterations > 0 else { return (best, bestScore.value) }

        // 每格的可选内容：空、所有活着的键，再加上这格现有的内容（可能来自已报废的键，留着不要钱）。
        var shared: [SlotFill] = [.empty]
        for symbol in input.aliveSymbols { shared.append(.key(symbol)) }
        var options: [[SlotFill]] = []
        options.reserveCapacity(positions.count)
        for index in positions {
            var local = shared
            if input.current[index] != .empty, !local.contains(input.current[index]) {
                local.append(input.current[index])
            }
            options.append(local)
        }
        guard options.contains(where: { $0.count > 1 }) else { return (best, bestScore.value) }

        for _ in 0..<iterations {
            let slot = Int(PuzzleRandom.uniform(below: UInt64(positions.count), using: &rng))
            let index = positions[slot]
            let choices = options[slot]
            let pick = choices[Int(PuzzleRandom.uniform(below: UInt64(choices.count), using: &rng))]
            if best[index] == pick { continue }
            var candidate = best
            candidate[index] = pick
            guard isFeasible(input, candidate) else { continue }
            let score = (value: value(input, candidate), presses: pressCount(input, candidate))
            if isBetter(score, than: bestScore) {
                best = candidate
                bestScore = score
            }
        }
        return (best, bestScore.value)
    }
}

// MARK: - 执行

/// 一局对局的驱动器。每次决策做一个动作，然后推进 `decisionInterval` 秒。
struct BotPlayer {
    /// 键盘或格子没变时，隔多久强制重规划一次（腐烂时钟秒）。
    private static let replanPeriod: Double = 5
    /// 决策次数硬上限之外再留的余量，保证任何情况下都不会死循环。
    private static let decisionSlack = 1000

    let config: BotConfig
    var state: RunState
    var rng: SplitMix64
    var target: [SlotFill]
    var lastSnapshot: Snapshot?
    var lastPlanClock: Double = -Double.greatestFiniteMagnitude
    /// 选中格子之后要按的键，下一次决策兑现。
    var pendingPress: KeySymbol?
    /// 残局：该救的数字键全报废了，只剩"还能不能再抬一点"的单步搜索，不再重规划。
    var endgame = false
    var presses = 0
    var tierTimes: [Double] = []

    struct Snapshot: Equatable {
        var kinds: [SlotKind]
        var alive: [KeySymbol]
    }

    init(puzzle: DailyPuzzle, config: BotConfig) {
        self.config = config
        self.state = RunState(puzzle: puzzle)
        self.rng = SplitMix64(seed: PuzzleSeed.hash(puzzle.seed))
        self.target = [SlotFill](repeating: .empty, count: puzzle.slots.count)
    }

    // MARK: 主循环

    mutating func run(trace: ((BotTraceEntry) -> Void)?) -> BotReport {
        let limit = Int(state.puzzle.runCapSeconds / max(config.decisionInterval, 0.01)) + Self.decisionSlack
        var decisions = 0
        while !state.phase.isEnded, decisions < limit {
            decisions += 1
            if let action = decide() {
                let label = describe(action)
                let events = state.apply(action)
                if case .pressKey = action, events.contains(where: { if case .slotChanged = $0 { return true } else { return false } }) {
                    presses += 1
                }
                record(events)
                trace?(BotTraceEntry(rotClock: state.rotClock, action: label, value: state.currentValue))
            } else {
                trace?(BotTraceEntry(rotClock: state.rotClock, action: "wait", value: state.currentValue))
            }
            if state.phase.isEnded { break }
            record(state.tick(config.decisionInterval))
        }
        let reason: EndReason
        if case .ended(let r) = state.phase {
            reason = r
        } else {
            // 只可能来自决策上限兜底；按时间上限记账。
            reason = .timeCap
        }
        return BotReport(
            seed: state.puzzle.seed,
            peak: state.peak,
            peakSlog: state.peak.slog10(),
            tiersCrossed: state.crossedTiers,
            tierTimes: tierTimes,
            presses: presses,
            endReason: reason,
            runSeconds: state.rotClock,
            slotKindsAtEnd: state.slots.map(\.kind),
            keysAtEnd: state.keys.map { $0.symbol.description }
        )
    }

    private mutating func record(_ events: [RunEvent]) {
        for event in events {
            if case .thresholdCrossed = event { tierTimes.append(state.rotClock) }
        }
    }

    // MARK: 决策

    private mutating func decide() -> RunAction? {
        if let choice = state.currentChoice { return resolve(choice) }
        ensurePlan()

        if let symbol = pendingPress {
            pendingPress = nil
            if let index = aliveKeyIndex(symbol) { return .pressKey(index) }
        }
        if let action = repairAction() {
            // 修好键之后局面重新有救。
            endgame = false
            return action
        }
        if let action = fillAction() { return action }

        let candidates = refreshCandidates()
        if let action = freezeAction(candidates) { return action }
        if let action = refreshAction(candidates) { return action }

        // 还有活着的数字键能把腐烂掉的格子救回来，就等腐烂再出手。
        if !endgame, canStillRefresh() { return nil }
        endgame = true
        if let action = salvageAction() { return action }
        return .end
    }

    // MARK: 规划

    private func snapshot() -> Snapshot {
        Snapshot(
            kinds: state.slots.map(\.kind),
            alive: state.keys.filter { !$0.isDead }.map(\.symbol)
        )
    }

    func planInput() -> PlanInput {
        var uses: [KeySymbol: Int] = [:]
        var symbols: [KeySymbol] = []
        symbols.reserveCapacity(state.keys.count)
        for key in state.keys {
            uses[key.symbol] = max(key.uses, 0)
            symbols.append(key.symbol)
        }
        return PlanInput(
            kinds: state.slots.map(\.kind),
            current: state.slots.indices.map { currentFill(at: $0) },
            symbols: symbols,
            uses: uses
        )
    }

    /// 一格现在装的东西在规划语义下是什么：
    /// 数字键还活着就按"还能救回原值"算，报废了就只值当前腐烂后的数。
    private func currentFill(at index: Int) -> SlotFill {
        let slot = state.slots[index]
        if slot.kind == .echo { return .empty }
        switch slot.content {
        case .empty:
            return .empty
        case .digit(let base, _):
            if aliveKeyIndex(.digit(base)) != nil { return .key(.digit(base)) }
            return .frozen(state.rottedDigit(at: index) ?? base)
        case .op(let symbol):
            return .key(symbol)
        }
    }

    private mutating func ensurePlan() {
        // 残局里目标由 salvage 直接改写，重规划只会把它推回一个救不动的布局。
        guard !endgame else { return }
        let snap = snapshot()
        let stale = state.rotClock - lastPlanClock >= Self.replanPeriod
        guard target.count != state.slots.count || lastSnapshot != snap || stale else { return }
        replan()
    }

    private mutating func replan() {
        let input = planInput()
        let seed = target.count == input.kinds.count ? target : nil
        target = BotPlanner.plan(input, iterations: config.searchIterations, seed: seed, using: &rng).layout
        lastSnapshot = snapshot()
        lastPlanClock = state.rotClock
        pendingPress = nil
    }

    // MARK: 填格

    private func matches(_ content: SlotContent, _ fill: SlotFill) -> Bool {
        switch (content, fill) {
        case (.empty, .empty):
            return true
        case (.digit, .frozen):
            // 冻结的意思就是"别动它"。
            return true
        case (.digit(let base, _), .key(.digit(let d))):
            return base == d
        case (.op(let a), .key(let b)):
            return !b.isDigit && a == b
        default:
            return false
        }
    }

    private func aliveKeyIndex(_ symbol: KeySymbol) -> Int? {
        state.keys.firstIndex { $0.symbol == symbol && !$0.isDead }
    }

    private func keyIndex(_ symbol: KeySymbol) -> Int? {
        state.keys.firstIndex { $0.symbol == symbol }
    }

    /// 按目标布局从左到右补齐；需要覆盖非首个空格时先选中。
    private mutating func fillAction() -> RunAction? {
        guard target.count == state.slots.count else { return nil }
        for index in state.slots.indices {
            guard state.slots[index].kind != .echo else { continue }
            if matches(state.slots[index].content, target[index]) { continue }
            switch target[index] {
            case .empty:
                return .clearSlot(index)
            case .frozen:
                // 只可能出现在它自己的格子里，`matches` 已经放行，走不到这里。
                continue
            case .key(let symbol):
                guard let key = aliveKeyIndex(symbol) else { continue }
                if state.selectedSlot == index { return .pressKey(key) }
                if state.selectedSlot == nil, state.firstFillableSlot == index { return .pressKey(key) }
                pendingPress = symbol
                return .selectSlot(index)
            }
        }
        return nil
    }

    // MARK: 维护

    struct RefreshCandidate {
        var index: Int
        var symbol: KeySymbol
        var value: BigNum
        /// 烂格重填不耗耐久，同样收益时优先。
        var free: Bool
    }

    /// 逐个数字格试算"把它救回目标数字"能把当前值抬到多少，只保留有正收益的。
    private mutating func refreshCandidates() -> [RefreshCandidate] {
        guard target.count == state.slots.count else { return [] }
        var out: [RefreshCandidate] = []
        let baseline = state.currentValue
        for index in state.slots.indices {
            let slot = state.slots[index]
            guard slot.kind != .echo, slot.kind != .stable else { continue }
            guard case .key(.digit(let d)) = target[index] else { continue }
            guard case .digit(let base, _) = slot.content, base == d else { continue }
            guard let rotted = state.rottedDigit(at: index), rotted < d else { continue }
            guard aliveKeyIndex(.digit(d)) != nil else { continue }
            let saved = slot.content
            state.slots[index].content = .digit(base: d, placedAt: state.rotClock)
            let refreshed = state.evaluate()
            state.slots[index].content = saved
            guard let refreshed else { continue }
            if let baseline, refreshed <= baseline { continue }
            out.append(
                RefreshCandidate(index: index, symbol: .digit(d), value: refreshed, free: slot.kind == .rotten)
            )
        }
        return out
    }

    /// 有格子该救但键已经报废、又没有修键可用。
    private func hasDeadRefreshNeed() -> Bool {
        guard target.count == state.slots.count else { return false }
        for index in state.slots.indices {
            let slot = state.slots[index]
            guard slot.kind != .echo, slot.kind != .stable else { continue }
            guard case .key(.digit(let d)) = target[index] else { continue }
            guard case .digit(let base, _) = slot.content, base == d else { continue }
            guard let rotted = state.rottedDigit(at: index), rotted < d else { continue }
            if aliveKeyIndex(.digit(d)) == nil { return true }
        }
        return false
    }

    private mutating func refreshAction(_ candidates: [RefreshCandidate]) -> RunAction? {
        var best: RefreshCandidate?
        for candidate in candidates {
            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.value > current.value || (candidate.value == current.value && candidate.free && !current.free) {
                best = candidate
            }
        }
        guard let best else { return nil }
        guard let key = aliveKeyIndex(best.symbol) else { return nil }
        if state.selectedSlot == best.index { return .pressKey(key) }
        pendingPress = best.symbol
        return .selectSlot(best.index)
    }

    // MARK: 道具

    /// 目标布局对各个键的需求强度：会腐烂的数字格算两份，其余算一份。
    private func needWeights() -> [(symbol: KeySymbol, weight: Int)] {
        guard target.count == state.slots.count else { return [] }
        var weights: [KeySymbol: Int] = [:]
        for index in state.slots.indices {
            guard state.slots[index].kind != .echo else { continue }
            var symbol: KeySymbol?
            switch target[index] {
            case .key(let s):
                symbol = s
            case .frozen:
                // 冻结说明这格的数字键已经报废，正是最该修的那一个。
                if case .digit(let base, _) = state.slots[index].content { symbol = .digit(base) }
            case .empty:
                symbol = nil
            }
            guard let symbol else { continue }
            let rots = symbol.isDigit && state.slots[index].kind != .stable
            weights[symbol, default: 0] += rots ? 2 : 1
        }
        // 只遍历数组，字典仅用于查表，保证顺序确定。
        return state.keys.compactMap { key in
            guard let weight = weights[key.symbol], weight > 0 else { return nil }
            return (key.symbol, weight)
        }
    }

    /// 目标布局最需要、且已经报废或只剩 1 点耐久的键。
    private func neediestBrokenKey() -> Int? {
        var bestIndex: Int?
        var bestWeight = 0
        for (symbol, weight) in needWeights() {
            guard let index = keyIndex(symbol), state.keys[index].uses <= 1 else { continue }
            if weight > bestWeight {
                bestWeight = weight
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func repairAction() -> RunAction? {
        guard let slot = state.inventory.firstIndex(where: { if case .repair = $0 { return true } else { return false } })
        else { return nil }
        guard let key = neediestBrokenKey(), !state.keys[key].isFull else { return nil }
        return .useItem(slot, target: key)
    }

    /// 至少两个格子该救，或者该救的键已经报废且没有修键时，冻结换时间。
    private func freezeAction(_ candidates: [RefreshCandidate]) -> RunAction? {
        guard !state.isFrozen else { return nil }
        guard let slot = state.inventory.firstIndex(where: { if case .freeze = $0 { return true } else { return false } })
        else { return nil }
        if candidates.count >= 2 { return .useItem(slot, target: nil) }
        if hasDeadRefreshNeed(), !state.hasRepairAvailable { return .useItem(slot, target: nil) }
        return nil
    }

    // MARK: 跨档选择

    /// 假想规划用的迭代数：候选组合很多，单个候选用轻量搜索比较，定下来之后再做一次完整重规划。
    private var hypotheticalIterations: Int { max(60, config.searchIterations / 4) }

    private mutating func resolve(_ choice: PendingChoice) -> RunAction {
        switch choice {
        case .addSlot(let choices):
            return resolveAddSlot(choices)
        case .convertSlot(let kind):
            return resolveConvertSlot(kind)
        case .repairNow:
            // 修键只能修回上限，满耐久的键会被引擎拒绝，只在能修的键里挑。
            var key = neediestBrokenKey() ?? weakestKeyIndex()
            if state.keys[key].isFull, let repairable = state.keys.indices.first(where: { !state.keys[$0].isFull }) {
                key = repairable
            }
            forcePlanAfterChoice()
            return .chooseRepairNow(keyIndex: key)
        }
    }

    private func weakestKeyIndex() -> Int {
        var best = 0
        for index in state.keys.indices where state.keys[index].uses < state.keys[best].uses { best = index }
        return best
    }

    private mutating func resolveAddSlot(_ choices: [SlotKind]) -> RunAction {
        let base = planInput()
        var bestKind = choices.first ?? .normal
        var bestPosition = base.kinds.count
        var bestScore: (value: BigNum?, presses: Int) = (nil, Int.max)
        for kind in choices {
            for position in 0...base.kinds.count {
                var input = base
                input.kinds.insert(kind, at: position)
                input.current.insert(.empty, at: position)
                let planned = BotPlanner.plan(input, iterations: hypotheticalIterations, seed: nil, using: &rng)
                let score = (value: planned.value, presses: BotPlanner.pressCount(input, planned.layout))
                if BotPlanner.isBetter(score, than: bestScore) {
                    bestScore = score
                    bestKind = kind
                    bestPosition = position
                }
            }
        }
        forcePlanAfterChoice()
        return .chooseAddSlot(kind: bestKind, position: bestPosition)
    }

    private mutating func resolveConvertSlot(_ kind: SlotKind) -> RunAction {
        let base = planInput()
        var bestIndex = 0
        var bestScore: (value: BigNum?, presses: Int) = (nil, Int.max)
        for index in base.kinds.indices {
            var input = base
            input.kinds[index] = kind
            if kind == .echo {
                input.current[index] = .empty
            } else if let rotted = state.rottedDigit(at: index) {
                // 引擎改格时按当前可见数字重新落位。
                input.current[index] = aliveKeyIndex(.digit(rotted)) != nil
                    ? .key(.digit(rotted))
                    : .frozen(rotted)
            }
            let planned = BotPlanner.plan(input, iterations: hypotheticalIterations, seed: nil, using: &rng)
            let score = (value: planned.value, presses: BotPlanner.pressCount(input, planned.layout))
            if BotPlanner.isBetter(score, than: bestScore) {
                bestScore = score
                bestIndex = index
            }
        }
        forcePlanAfterChoice()
        return .chooseConvertSlot(bestIndex)
    }

    private mutating func forcePlanAfterChoice() {
        lastSnapshot = nil
        lastPlanClock = -Double.greatestFiniteMagnitude
        pendingPress = nil
        // 加格、改格、修键都可能让局面重新有救，退出残局模式。
        endgame = false
    }

    // MARK: 结束判断

    /// 目标布局里还有"会腐烂、且对应数字键还活着"的格子，也就是还救得动。
    private func canStillRefresh() -> Bool {
        guard target.count == state.slots.count else { return true }
        // 修键只在"目标要用的键快报废了"时才算救得动；这时 repairAction 已经先一步把它用掉了，
        // 所以这里是一道保险，而不是让机器人抱着一个用不上的修键空转到时间上限。
        if state.hasRepairAvailable, neediestBrokenKey() != nil { return true }
        for index in state.slots.indices {
            let kind = state.slots[index].kind
            guard kind != .echo, kind != .stable else { continue }
            guard case .key(.digit(let d)) = target[index] else { continue }
            if aliveKeyIndex(.digit(d)) != nil { return true }
        }
        return false
    }

    /// 残局的单步捞底：把任意活着的键放进任意格子，看能不能把当前值再抬高一点。
    /// 命中时顺手把目标布局改成这一步的结果，避免下一次决策又被填格逻辑改回去。
    private mutating func salvageAction() -> RunAction? {
        let alive = state.keys.filter { !$0.isDead }.map(\.symbol)
        guard !alive.isEmpty, target.count == state.slots.count else { return nil }
        let baseline = state.currentValue
        var best: (index: Int, symbol: KeySymbol, value: BigNum)?
        for index in state.slots.indices {
            guard state.slots[index].kind != .echo else { continue }
            let saved = state.slots[index].content
            for symbol in alive {
                if case .digit(let d) = symbol {
                    state.slots[index].content = .digit(base: d, placedAt: state.rotClock)
                } else {
                    state.slots[index].content = .op(symbol)
                }
                guard let probe = state.evaluate() else { continue }
                if let baseline, probe <= baseline { continue }
                if let current = best, probe <= current.value { continue }
                best = (index, symbol, probe)
            }
            state.slots[index].content = saved
        }
        guard let best, let key = aliveKeyIndex(best.symbol) else { return nil }
        target[best.index] = .key(best.symbol)
        if state.selectedSlot == best.index { return .pressKey(key) }
        pendingPress = best.symbol
        return .selectSlot(best.index)
    }

    // MARK: 轨迹

    private func describe(_ action: RunAction) -> String {
        switch action {
        case .pressKey(let index):
            let symbol = state.keys.indices.contains(index) ? state.keys[index].symbol.description : "?"
            return "press \(symbol)"
        case .selectSlot(let index):
            return index.map { "select #\($0)" } ?? "deselect"
        case .clearSlot(let index):
            return "clear #\(index)"
        case .useItem(let index, let target):
            let item = state.inventory.indices.contains(index) ? state.inventory[index] : .freeze(seconds: 0)
            switch item {
            case .repair(let amount):
                let symbol = target.flatMap { state.keys.indices.contains($0) ? state.keys[$0].symbol.description : nil }
                return "repair+\(amount) → \(symbol ?? "?")"
            case .freeze(let seconds):
                return "freeze \(seconds)s"
            }
        case .chooseAddSlot(let kind, let position):
            return "addSlot \(kind.rawValue)@\(position)"
        case .chooseConvertSlot(let index):
            return "convertSlot #\(index)"
        case .chooseRepairNow(let index):
            let symbol = state.keys.indices.contains(index) ? state.keys[index].symbol.description : "?"
            return "repairNow → \(symbol)"
        case .end:
            return "end"
        }
    }
}

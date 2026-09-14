import Foundation

// MARK: - 确定性随机工具

/// 只依赖调用方传入的生成器，不读任何全局状态。
///
/// 所有需要"按权重挑一个"的地方都要求调用方把候选排成固定顺序的数组，
/// 绝不直接遍历 `Dictionary`，否则同种子会因为哈希顺序产生不同的题。
enum PuzzleRandom {
    /// `[0, upperBound)` 上的均匀整数，拒绝采样消除取模偏差。
    static func uniform<G: RandomNumberGenerator>(below upperBound: UInt64, using generator: inout G) -> UInt64 {
        precondition(upperBound > 0, "上界必须为正")
        if upperBound == 1 { return 0 }
        // 2^64 mod upperBound：落在这段里的取值会让低位分布不均，重抽。
        let cutoff = (0 &- upperBound) % upperBound
        var raw = generator.next()
        while raw < cutoff { raw = generator.next() }
        return raw % upperBound
    }

    /// 闭区间上的均匀整数。
    static func uniform<G: RandomNumberGenerator>(in range: ClosedRange<Int>, using generator: inout G) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(uniform(below: span, using: &generator))
    }

    /// `[0, 1)` 上的均匀浮点数，取 53 位有效位。
    static func unitDouble<G: RandomNumberGenerator>(using generator: inout G) -> Double {
        Double(generator.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// 闭区间上的均匀浮点数（实际取值落在 `[lower, upper)`）。
    static func uniform<G: RandomNumberGenerator>(in range: ClosedRange<Double>, using generator: inout G) -> Double {
        range.lowerBound + unitDouble(using: &generator) * (range.upperBound - range.lowerBound)
    }

    /// 概率为 `numerator / denominator` 的判定。
    static func chance<G: RandomNumberGenerator>(_ numerator: Int, outOf denominator: Int, using generator: inout G) -> Bool {
        precondition(denominator > 0, "分母必须为正")
        return Int(uniform(below: UInt64(denominator), using: &generator)) < numerator
    }

    /// 按权重取一个下标；数组为空或权重全非正时返回 nil。
    static func weightedIndex<G: RandomNumberGenerator>(_ weights: [Int], using generator: inout G) -> Int? {
        var total = 0
        for weight in weights where weight > 0 { total += weight }
        guard total > 0 else { return nil }
        var ticket = Int(uniform(below: UInt64(total), using: &generator))
        for (index, weight) in weights.enumerated() where weight > 0 {
            ticket -= weight
            if ticket < 0 { return index }
        }
        return weights.lastIndex(where: { $0 > 0 })
    }

    /// 按权重取一个元素。`items` 的顺序由调用方固定。
    static func weightedPick<T, G: RandomNumberGenerator>(
        _ items: [(value: T, weight: Int)],
        using generator: inout G
    ) -> T? {
        guard let index = weightedIndex(items.map(\.weight), using: &generator) else { return nil }
        return items[index].value
    }

    /// 按权重不放回地取至多 `count` 个元素，返回顺序即抽中顺序。
    static func weightedSample<T, G: RandomNumberGenerator>(
        _ items: [(value: T, weight: Int)],
        count: Int,
        using generator: inout G
    ) -> [T] {
        var pool = items
        var picked: [T] = []
        picked.reserveCapacity(max(count, 0))
        while picked.count < count, !pool.isEmpty {
            guard let index = weightedIndex(pool.map(\.weight), using: &generator) else { break }
            picked.append(pool[index].value)
            pool.remove(at: index)
        }
        return picked
    }
}

// MARK: - 每日题生成器

/// 由种子和平衡参数确定性地生成一道题（设计文档 4.2、4.3）。
///
/// 生成过程只用 `SplitMix64(seed: PuzzleSeed.hash(seed))`，
/// 不依赖时间、语言环境、字典遍历顺序等任何外部状态。
public enum PuzzleGenerator {
    /// 解锁键奖励的候选池权重（设计文档 3.6 的道具表）。
    private static let powWeight = 6
    private static let factorialWeight = 6
    private static let parenWeight = 3
    private static let digitWeight = 2
    private static let digitNineWeight = 4
    private static let plusWeight = 1
    private static let timesWeight = 2
    /// `!` 最早出现的档位（从 0 数）。
    private static let factorialMinTier = 3
    /// 耐久重抽的次数上限，超过就走兜底夹取，保证不会挂死。
    private static let durabilityRedrawLimit = 1000
    /// 奖励种类的固定顺序，替代 `rewardWeights` 的字典遍历。
    private static let rewardKinds = ["unlockKey", "addSlot", "convertSlot", "repair", "freeze"]

    public static func generate(seed: String, balance: BalanceParams = .default) -> DailyPuzzle {
        var rng = SplitMix64(seed: PuzzleSeed.hash(seed))
        let slots = makeSlots(balance: balance, using: &rng)
        let keys = makeKeys(balance: balance, using: &rng)
        let rotInterval = PuzzleRandom.uniform(in: balance.rotInterval, using: &rng)
        let thresholds = makeThresholds(balance: balance)
        let rewards = makeRewards(count: thresholds.count, keys: keys, balance: balance, using: &rng)
        return DailyPuzzle(
            seed: seed,
            slots: slots,
            keys: keys,
            rotInterval: rotInterval,
            thresholds: thresholds,
            rewards: rewards,
            runCapSeconds: balance.runCapSeconds,
            inventoryCap: 3
        )
    }

    // MARK: 格子

    /// 起手格子：数量在区间内，至多一个特殊格，起手不出回声格。
    private static func makeSlots<G: RandomNumberGenerator>(balance: BalanceParams, using rng: inout G) -> [SlotKind] {
        let count = PuzzleRandom.uniform(in: balance.startSlots, using: &rng)
        precondition(count > 0, "起手格子数必须为正")
        var slots = [SlotKind](repeating: .normal, count: count)
        // 一半的题完全是普通格；另一半有且只有一个特殊格，位置随机。
        if PuzzleRandom.chance(1, outOf: 2, using: &rng) {
            let candidates: [SlotKind] = [.stable, .amp, .rotten]
            let kind = candidates[PuzzleRandom.uniform(in: 0...(candidates.count - 1), using: &rng)]
            let position = PuzzleRandom.uniform(in: 0...(count - 1), using: &rng)
            slots[position] = kind
        }
        return slots
    }

    // MARK: 起手键

    private static func makeKeys<G: RandomNumberGenerator>(balance: BalanceParams, using rng: inout G) -> [KeyDef] {
        var symbols = makeDigitSymbols(balance: balance, using: &rng)
        symbols.append(contentsOf: makeOperatorSymbols(balance: balance, using: &rng))
        let durabilities = drawDurabilities(count: symbols.count, balance: balance, using: &rng)
        var keys = zip(symbols, durabilities).map { KeyDef($0, uses: $1) }
        keys.sort { $0.symbol.sortOrder < $1.symbol.sortOrder }
        return keys
    }

    /// 数字键：互不相同，1–9 权重 4，0 权重 1。
    private static func makeDigitSymbols<G: RandomNumberGenerator>(
        balance: BalanceParams,
        using rng: inout G
    ) -> [KeySymbol] {
        let wanted = PuzzleRandom.uniform(in: balance.digitKeys, using: &rng)
        // 至少两个不同的数字（设计文档 4.3），最多十个（数字总共就这么多）。
        let count = min(max(wanted, 2), 10)
        let pool: [(value: Int, weight: Int)] = (0...9).map { ($0, $0 == 0 ? 1 : 4) }
        let digits = PuzzleRandom.weightedSample(pool, count: count, using: &rng)
        precondition(Set(digits).count == digits.count && digits.count >= 2, "数字键必须互不相同且至少两个")
        return digits.map { KeySymbol.digit($0) }
    }

    /// 运算符键：从 `+`、`×` 里不放回地抽，15% 概率把其中一个换成 `^`。
    private static func makeOperatorSymbols<G: RandomNumberGenerator>(
        balance: BalanceParams,
        using rng: inout G
    ) -> [KeySymbol] {
        let wanted = PuzzleRandom.uniform(in: balance.opKeys, using: &rng)
        let count = min(max(wanted, 1), 2)
        let pool: [(value: KeySymbol, weight: Int)] = [(.plus, 1), (.times, 1)]
        let ops = PuzzleRandom.weightedSample(pool, count: count, using: &rng)
        // 起手永远没有 `^` 和 `!`，它们只能从阈值奖励里来。
        precondition(ops.contains(.plus) || ops.contains(.times), "起手至少要有 + 或 × 之一")
        return ops
    }

    /// 每个键独立抽耐久；总耐久不在校准区间内就整组重抽。
    private static func drawDurabilities<G: RandomNumberGenerator>(
        count: Int,
        balance: BalanceParams,
        using rng: inout G
    ) -> [Int] {
        guard count > 0 else { return [] }
        var lastDraw: [Int] = []
        for _ in 0..<durabilityRedrawLimit {
            var values: [Int] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                values.append(PuzzleRandom.uniform(in: balance.keyDurability, using: &rng))
            }
            if balance.totalDurability.contains(values.reduce(0, +)) { return values }
            lastDraw = values
        }
        // 兜底：单键区间和总区间的组合可能极难甚至不可能同时满足，
        // 这时在单键区间内轮流加减，把总和推向目标区间，绝不死循环。
        return clampTotal(lastDraw, balance: balance)
    }

    private static func clampTotal(_ values: [Int], balance: BalanceParams) -> [Int] {
        var values = values
        let low = balance.keyDurability.lowerBound
        let high = balance.keyDurability.upperBound
        var total = values.reduce(0, +)
        var cursor = 0
        while total > balance.totalDurability.upperBound {
            guard values.contains(where: { $0 > low }) else { break }
            let index = cursor % values.count
            cursor += 1
            if values[index] > low {
                values[index] -= 1
                total -= 1
            }
        }
        cursor = 0
        while total < balance.totalDurability.lowerBound {
            guard values.contains(where: { $0 < high }) else { break }
            let index = cursor % values.count
            cursor += 1
            if values[index] < high {
                values[index] += 1
                total += 1
            }
        }
        return values
    }

    // MARK: 阈值

    private static func makeThresholds(balance: BalanceParams) -> [BigNum] {
        let values: [BigNum] = balance.thresholds.map { text in
            guard let value = BigNum(threshold: text) else {
                preconditionFailure("阈值 \(text) 无法解析")
            }
            return value
        }
        if values.count > 1 {
            for index in 1..<values.count {
                precondition(values[index - 1] < values[index], "阈值必须严格递增")
            }
        }
        return values
    }

    // MARK: 奖励

    private static func makeRewards<G: RandomNumberGenerator>(
        count: Int,
        keys: [KeyDef],
        balance: BalanceParams,
        using rng: inout G
    ) -> [Reward] {
        guard count > 0 else { return [] }
        let keyboard = Set(keys.map(\.symbol))

        // T1 必须解锁 `^`（设计文档 3.6、4.3）。起手键盘永远没有 `^`。
        // 校准发现：解锁落在 T2 时，1e6 靠纯数字拼不到，整局卡死；起手带 `^` 再送 `!` 则是暴击日。
        let forcedTier = 0
        let forcedSymbol: KeySymbol = .pow
        let forcedUses = PuzzleRandom.uniform(in: balance.keyDurability, using: &rng)
        // 先把强制档的符号占住，后面的解锁档就不会重复它（哪怕强制档排在第二个）。
        var unlocked: Set<KeySymbol> = [forcedSymbol]

        var rewards: [Reward] = []
        rewards.reserveCapacity(count)
        for tier in 0..<count {
            if tier == forcedTier {
                rewards.append(.unlockKeys([KeyDef(forcedSymbol, uses: forcedUses)]))
                continue
            }
            rewards.append(
                makeReward(tier: tier, keyboard: keyboard, unlocked: &unlocked, balance: balance, using: &rng)
            )
        }
        return rewards
    }

    private static func makeReward<G: RandomNumberGenerator>(
        tier: Int,
        keyboard: Set<KeySymbol>,
        unlocked: inout Set<KeySymbol>,
        balance: BalanceParams,
        using rng: inout G
    ) -> Reward {
        let candidates = rewardKinds.map { (value: $0, weight: balance.rewardWeights[$0] ?? 0) }
        let kind = PuzzleRandom.weightedPick(candidates, using: &rng) ?? "repair"
        switch kind {
        case "unlockKey":
            guard let defs = makeUnlockKeys(tier: tier, taken: keyboard.union(unlocked), balance: balance, using: &rng) else {
                // 候选池被抽空（理论上要先解锁十几个键），退化成修键。
                return .repair(amount: balance.repairAmount)
            }
            for def in defs { unlocked.insert(def.symbol) }
            return .unlockKeys(defs)
        case "addSlot":
            return makeAddSlot(balance: balance, using: &rng)
        case "convertSlot":
            return makeConvertSlot(balance: balance, using: &rng)
        case "freeze":
            return .freeze(seconds: balance.freezeSeconds)
        default:
            return .repair(amount: balance.repairAmount)
        }
    }

    /// 解锁键候选池：键盘上没有、也没被前面的档解锁过的键。
    /// `(` 与 `)` 成对出现，一档送两个。
    private static func makeUnlockKeys<G: RandomNumberGenerator>(
        tier: Int,
        taken: Set<KeySymbol>,
        balance: BalanceParams,
        using rng: inout G
    ) -> [KeyDef]? {
        var pool: [(value: [KeySymbol], weight: Int)] = []
        if !taken.contains(.pow) { pool.append(([.pow], powWeight)) }
        // `!` 每加一个就多一层，是跳档键，只在第 4 档起出现，且耐久很低。
        if tier >= factorialMinTier, !taken.contains(.factorial) { pool.append(([.factorial], factorialWeight)) }
        if !taken.contains(.lparen), !taken.contains(.rparen) {
            pool.append(([.lparen, .rparen], parenWeight))
        }
        for digit in 1...9 where !taken.contains(.digit(digit)) {
            pool.append(([.digit(digit)], digit == 9 ? digitNineWeight : digitWeight))
        }
        if !taken.contains(.plus) { pool.append(([.plus], plusWeight)) }
        if !taken.contains(.times) { pool.append(([.times], timesWeight)) }
        guard let symbols = PuzzleRandom.weightedPick(pool, using: &rng) else { return nil }
        // 成对的括号共用一次耐久抽取，两个键耐久相同；`!` 走单独的低耐久区间。
        let uses = symbols == [.factorial]
            ? PuzzleRandom.uniform(in: balance.factorialUses, using: &rng)
            : PuzzleRandom.uniform(in: balance.keyDurability, using: &rng)
        return symbols.map { KeyDef($0, uses: uses) }
    }

    /// 加格档：2 到 3 种候选类型，五种格子都可能出现，回声格权重最低。
    private static func makeAddSlot<G: RandomNumberGenerator>(balance: BalanceParams, using rng: inout G) -> Reward {
        let count = PuzzleRandom.uniform(in: 2...3, using: &rng)
        let pool = SlotKind.allCases.map { (value: $0, weight: balance.slotKindWeights[$0.rawValue] ?? 0) }
        let picked = Set(PuzzleRandom.weightedSample(pool, count: count, using: &rng))
        // 输出顺序固定成 `allCases` 的顺序，抽中顺序不影响结果。
        return .addSlot(choices: SlotKind.allCases.filter { picked.contains($0) })
    }

    /// 改格档：一种目标类型，不会是普通格。
    private static func makeConvertSlot<G: RandomNumberGenerator>(balance: BalanceParams, using rng: inout G) -> Reward {
        let pool = SlotKind.allCases
            .filter { $0 != .normal }
            .map { (value: $0, weight: balance.slotKindWeights[$0.rawValue] ?? 0) }
        let kind = PuzzleRandom.weightedPick(pool, using: &rng) ?? .stable
        return .convertSlot(kind)
    }
}

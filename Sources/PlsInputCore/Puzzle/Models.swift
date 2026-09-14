import Foundation

/// 键盘上的一个符号。
public enum KeySymbol: Hashable, Codable, Sendable, CustomStringConvertible {
    case digit(Int)
    case plus
    case times
    case pow
    case factorial
    case lparen
    case rparen

    public var isDigit: Bool {
        if case .digit = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .digit(let d): return String(d)
        case .plus: return "+"
        case .times: return "×"
        case .pow: return "^"
        case .factorial: return "!"
        case .lparen: return "("
        case .rparen: return ")"
        }
    }

    /// 键盘上的固定排序：数字在前，运算符在后。
    public var sortOrder: Int {
        switch self {
        case .digit(let d): return d
        case .plus: return 10
        case .times: return 11
        case .pow: return 12
        case .factorial: return 13
        case .lparen: return 14
        case .rparen: return 15
        }
    }
}

/// 一个键的定义：符号和初始耐久。
public struct KeyDef: Hashable, Codable, Sendable {
    public var symbol: KeySymbol
    public var uses: Int

    public init(_ symbol: KeySymbol, uses: Int) {
        self.symbol = symbol
        self.uses = uses
    }
}

/// 格子类型，规则见设计文档 3.2 节。
public enum SlotKind: String, Codable, Sendable, CaseIterable, Hashable {
    case normal
    case stable
    case echo
    case amp
    case rotten
}

/// 跨阈值发放的道具。
public enum Reward: Hashable, Codable, Sendable {
    /// 键盘加入新键；括号成对出现时是两个。
    case unlockKeys([KeyDef])
    /// 玩家从候选类型里选一种，再选位置插入。
    case addSlot(choices: [SlotKind])
    /// 玩家选一个已有格子改成该类型。
    case convertSlot(SlotKind)
    /// 进背包：给一个键加耐久。
    case repair(amount: Int)
    /// 进背包：腐烂时钟暂停。
    case freeze(seconds: Double)
}

/// 一道每日题。由种子和平衡参数确定性生成。
public struct DailyPuzzle: Hashable, Codable, Sendable {
    public var seed: String
    public var slots: [SlotKind]
    public var keys: [KeyDef]
    public var rotInterval: Double
    /// 与 `rewards` 等长、严格递增。
    public var thresholds: [BigNum]
    public var rewards: [Reward]
    public var runCapSeconds: Double
    public var inventoryCap: Int

    public init(
        seed: String,
        slots: [SlotKind],
        keys: [KeyDef],
        rotInterval: Double,
        thresholds: [BigNum],
        rewards: [Reward],
        runCapSeconds: Double,
        inventoryCap: Int = 3
    ) {
        self.seed = seed
        self.slots = slots
        self.keys = keys
        self.rotInterval = rotInterval
        self.thresholds = thresholds
        self.rewards = rewards
        self.runCapSeconds = runCapSeconds
        self.inventoryCap = inventoryCap
    }
}

/// 平衡参数，对应远程配置 `balance` 数组里一条的内容（不含 `applyFrom`）。
public struct BalanceParams: Hashable, Codable, Sendable {
    public var startSlots: ClosedRange<Int>
    public var digitKeys: ClosedRange<Int>
    public var opKeys: ClosedRange<Int>
    public var keyDurability: ClosedRange<Int>
    public var totalDurability: ClosedRange<Int>
    public var rotInterval: ClosedRange<Double>
    public var thresholds: [String]
    /// 键：unlockKey、addSlot、convertSlot、repair、freeze。
    public var rewardWeights: [String: Int]
    /// 键：SlotKind 的 rawValue。
    public var slotKindWeights: [String: Int]
    public var repairAmount: Int
    public var freezeSeconds: Double
    public var runCapSeconds: Double

    public init(
        startSlots: ClosedRange<Int>,
        digitKeys: ClosedRange<Int>,
        opKeys: ClosedRange<Int>,
        keyDurability: ClosedRange<Int>,
        totalDurability: ClosedRange<Int>,
        rotInterval: ClosedRange<Double>,
        thresholds: [String],
        rewardWeights: [String: Int],
        slotKindWeights: [String: Int],
        repairAmount: Int,
        freezeSeconds: Double,
        runCapSeconds: Double
    ) {
        self.startSlots = startSlots
        self.digitKeys = digitKeys
        self.opKeys = opKeys
        self.keyDurability = keyDurability
        self.totalDurability = totalDurability
        self.rotInterval = rotInterval
        self.thresholds = thresholds
        self.rewardWeights = rewardWeights
        self.slotKindWeights = slotKindWeights
        self.repairAmount = repairAmount
        self.freezeSeconds = freezeSeconds
        self.runCapSeconds = runCapSeconds
    }

    /// 与仓库 `remote/config.json` 初版一致的内置默认值。
    public static let `default` = BalanceParams(
        startSlots: 4...5,
        digitKeys: 3...4,
        opKeys: 1...2,
        keyDurability: 6...15,
        totalDurability: 45...80,
        rotInterval: 2.5...4.0,
        thresholds: ["1e3", "1e6", "1e12", "1e30", "1e100", "10^10^3", "10^10^6", "10^10^10", "10^10^100", "10^^4"],
        rewardWeights: ["unlockKey": 30, "addSlot": 30, "convertSlot": 15, "repair": 15, "freeze": 10],
        slotKindWeights: ["normal": 20, "stable": 25, "amp": 25, "rotten": 20, "echo": 10],
        repairAmount: 8,
        freezeSeconds: 10,
        runCapSeconds: 300
    )
}

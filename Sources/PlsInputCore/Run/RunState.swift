import Foundation

/// 格子里的内容。数字记录填入时的原值和填入时刻（腐烂时钟）。
public enum SlotContent: Hashable, Codable, Sendable {
    case empty
    case digit(base: Int, placedAt: Double)
    case op(KeySymbol)

    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }
}

public struct Slot: Hashable, Codable, Sendable {
    public var kind: SlotKind
    public var content: SlotContent

    public init(kind: SlotKind, content: SlotContent = .empty) {
        self.kind = kind
        self.content = content
    }
}

public struct KeyState: Hashable, Codable, Sendable {
    public var symbol: KeySymbol
    public var uses: Int

    public init(symbol: KeySymbol, uses: Int) {
        self.symbol = symbol
        self.uses = uses
    }

    public var isDead: Bool { uses <= 0 }
}

/// 背包里的道具。
public enum Item: Hashable, Codable, Sendable {
    case repair(amount: Int)
    case freeze(seconds: Double)
}

/// 需要玩家做出的选择。排队处理，队首生效，期间腐烂时钟暂停。
public enum PendingChoice: Hashable, Codable, Sendable {
    case addSlot(choices: [SlotKind])
    case convertSlot(SlotKind)
    /// 背包已满，新得的修键必须立即使用。
    case repairNow(amount: Int)
}

public enum EndReason: String, Codable, Sendable, Hashable {
    case keysExhausted
    case playerEnded
    case timeCap
}

public enum RunPhase: Hashable, Codable, Sendable {
    case ready
    case running
    case ended(EndReason)

    public var isEnded: Bool {
        if case .ended = self { return true }
        return false
    }
}

/// 一局的完整状态。纯值类型，可编解码，同样的动作与时钟序列必得到同样的结果。
public struct RunState: Hashable, Codable, Sendable {
    public var puzzle: DailyPuzzle
    public var slots: [Slot]
    public var keys: [KeyState]
    public var inventory: [Item]
    /// 腐烂时钟，秒。只在运行中、未冻结、无待选时前进。
    public var rotClock: Double
    public var freezeRemaining: Double
    public var phase: RunPhase
    public var selectedSlot: Int?
    /// 整局合法峰值；从未合法时为 0。
    public var peak: BigNum
    /// 已发放的阈值档数；阈值递增，按序发放，用计数即可。
    public var crossedTiers: Int
    public var pendingChoices: [PendingChoice]
    /// 当前显示值；nil 表示表达式不合法。
    public var currentValue: BigNum?

    public init(puzzle: DailyPuzzle) {
        self.puzzle = puzzle
        self.slots = puzzle.slots.map { Slot(kind: $0) }
        self.keys = puzzle.keys.map { KeyState(symbol: $0.symbol, uses: $0.uses) }
        self.inventory = []
        self.rotClock = 0
        self.freezeRemaining = 0
        self.phase = .ready
        self.selectedSlot = nil
        self.peak = .zero
        self.crossedTiers = 0
        self.pendingChoices = []
        self.currentValue = nil
    }

    public var isFrozen: Bool { freezeRemaining > 0 }
    public var currentChoice: PendingChoice? { pendingChoices.first }
    public var nextThreshold: BigNum? {
        crossedTiers < puzzle.thresholds.count ? puzzle.thresholds[crossedTiers] : nil
    }

    // MARK: - 有效内容

    /// 腐烂后的数字（未增幅）。非数字返回 nil。
    public func rottedDigit(at index: Int) -> Int? {
        guard slots.indices.contains(index) else { return nil }
        let slot = slots[index]
        guard case .digit(let base, let placedAt) = slot.content else { return nil }
        let interval: Double
        switch slot.kind {
        case .stable:
            return base
        case .rotten:
            interval = puzzle.rotInterval / 2
        default:
            interval = puzzle.rotInterval
        }
        let steps = Int(((rotClock - placedAt) / interval).rounded(.down))
        return max(0, base - max(0, steps))
    }

    /// 格子的有效词元：回声解析到源，增幅翻倍。空返回 nil。
    public func effectiveToken(at index: Int) -> Token? {
        guard slots.indices.contains(index) else { return nil }
        let slot = slots[index]
        if slot.kind == .echo {
            let source = index - 2
            guard source >= 0 else { return nil }
            return effectiveToken(at: source)
        }
        switch slot.content {
        case .empty:
            return nil
        case .op(let symbol):
            return Token(symbol: symbol)
        case .digit:
            guard var d = rottedDigit(at: index) else { return nil }
            if slot.kind == .amp { d *= 2 }
            return .number(String(d))
        }
    }

    /// 给界面用的显示文本。
    public func effectiveText(at index: Int) -> String? {
        guard let token = effectiveToken(at: index) else { return nil }
        switch token {
        case .number(let s): return s
        case .plus: return "+"
        case .times: return "×"
        case .pow: return "^"
        case .factorial: return "!"
        case .lparen: return "("
        case .rparen: return ")"
        }
    }

    public var tokens: [Token] {
        slots.indices.compactMap { effectiveToken(at: $0) }
    }

    public func evaluate() -> BigNum? {
        Expression.evaluate(tokens)
    }

    /// 首个可直接填入的空格（跳过回声格）。
    public var firstFillableSlot: Int? {
        slots.indices.first { slots[$0].content.isEmpty && slots[$0].kind != .echo }
    }

    public var allKeysDead: Bool { keys.allSatisfy(\.isDead) }

    public var hasRepairAvailable: Bool {
        inventory.contains { if case .repair = $0 { return true } else { return false } }
            || pendingChoices.contains { if case .repairNow = $0 { return true } else { return false } }
    }
}

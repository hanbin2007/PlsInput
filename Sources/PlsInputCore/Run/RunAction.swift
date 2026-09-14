import Foundation

/// 玩家动作。
public enum RunAction: Hashable, Codable, Sendable {
    case pressKey(Int)
    /// nil 取消选中；再次选中同一格也取消。
    case selectSlot(Int?)
    case clearSlot(Int)
    /// 背包序号；修键需要目标键序号。
    case useItem(Int, target: Int?)
    case chooseAddSlot(kind: SlotKind, position: Int)
    case chooseConvertSlot(Int)
    case chooseRepairNow(keyIndex: Int)
    case end
}

public enum RejectReason: Hashable, Sendable {
    case ended
    case notRunning
    case choicePending
    case noChoicePending
    case invalidIndex
    case keyDead
    case noEmptySlot
    case echoSlot
    case badChoice
    case needsTarget
}

/// 状态机对外的事件。序号指向动作执行后的状态。
public enum RunEvent: Hashable, Sendable {
    case started
    case slotChanged(Int)
    case keyUsed(Int, remaining: Int)
    case keyDied(Int)
    case valueChanged(BigNum?)
    case newPeak(BigNum)
    case thresholdCrossed(tier: Int, reward: Reward)
    case keysUnlocked([KeyDef])
    case itemAdded(Item)
    case itemUsed(Item)
    case choiceRequired(PendingChoice)
    case slotAdded(Int, SlotKind)
    case slotConverted(Int, SlotKind)
    case freezeStarted(Double)
    case freezeEnded
    case rejected(RejectReason)
    case ended(EndReason)
}

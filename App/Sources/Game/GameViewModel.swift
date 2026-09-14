import Foundation
import Observation
import PlsInputCore
import UIKit

/// 驱动一局：定时推进腐烂时钟，把动作交给状态机，把事件翻译成界面反馈。
@MainActor
@Observable
final class GameViewModel {
    enum Mode: Equatable {
        case daily
        case practice
    }

    /// 界面当前处于哪种交互模式。
    enum Interaction: Equatable {
        case normal
        case pickRepairTarget(inventoryIndex: Int)
        case pickKind(choices: [SlotKind])
        case pickInsertPosition(kind: SlotKind)
        case pickConvertTarget(kind: SlotKind)
        case pickRepairNowTarget(amount: Int)

        var isChoice: Bool {
            switch self {
            case .normal, .pickRepairTarget: return false
            default: return true
            }
        }
    }

    struct Toast: Equatable {
        var id: Int
        var text: String
    }

    let mode: Mode
    private(set) var state: RunState
    private(set) var interaction: Interaction = .normal
    private(set) var toast: Toast?
    /// 每次刷新峰值加一，用来触发动画。
    private(set) var peakPulse = 0
    private(set) var isRunningLoop = false
    var hapticsEnabled = true
    var onPersist: ((RunState) -> Void)?
    var onEnded: ((RunState) -> Void)?

    private var loop: Task<Void, Never>?
    private var lastTickAt: Date?
    private var persistAccumulator: Double = 0
    private var toastCounter = 0
    private var toastTask: Task<Void, Never>?

    init(mode: Mode, state: RunState) {
        self.mode = mode
        self.state = state
        refreshInteraction()
    }

    // MARK: - 派生

    var isEnded: Bool { state.phase.isEnded }
    var displayText: String { state.currentValue.map(BigNumFormatter.string) ?? "—" }
    var peakText: String { BigNumFormatter.string(state.peak) }
    var nextThresholdText: String? { state.nextThreshold.map(BigNumFormatter.string) }
    var clockText: String {
        let seconds = Int(state.rotClock)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// 数字格距离下一次腐烂的进度，0 到 1；不腐烂的格子返回 nil。
    func decayProgress(at index: Int) -> Double? {
        guard state.slots.indices.contains(index) else { return nil }
        let slot = state.slots[index]
        guard case .digit(let base, let placedAt) = slot.content else { return nil }
        guard slot.kind != .stable, slot.kind != .echo else { return nil }
        guard let current = state.rottedDigit(at: index), current > 0, base > 0 else { return nil }
        let interval = slot.kind == .rotten ? state.puzzle.rotInterval / 2 : state.puzzle.rotInterval
        let elapsed = state.rotClock - placedAt
        let within = elapsed - (elapsed / interval).rounded(.down) * interval
        return min(max(within / interval, 0), 1)
    }

    // MARK: - 时钟

    func resume() {
        guard loop == nil, !isEnded else { return }
        lastTickAt = Date()
        isRunningLoop = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.tickNow()
            }
        }
    }

    func pause() {
        loop?.cancel()
        loop = nil
        lastTickAt = nil
        isRunningLoop = false
        persist()
    }

    private func tickNow() {
        guard let last = lastTickAt else {
            lastTickAt = Date()
            return
        }
        let now = Date()
        let elapsed = min(now.timeIntervalSince(last), 0.5)
        lastTickAt = now
        guard elapsed > 0 else { return }
        let events = state.tick(elapsed)
        handle(events)
        persistAccumulator += elapsed
        if persistAccumulator >= 1 {
            persistAccumulator = 0
            persist()
        }
    }

    private func persist() {
        onPersist?(state)
    }

    // MARK: - 玩家操作

    func pressKey(_ index: Int) {
        switch interaction {
        case .pickRepairTarget(let inventoryIndex):
            interaction = .normal
            apply(.useItem(inventoryIndex, target: index))
        case .pickRepairNowTarget:
            apply(.chooseRepairNow(keyIndex: index))
        case .normal:
            apply(.pressKey(index))
        default:
            break
        }
    }

    func tapSlot(_ index: Int) {
        switch interaction {
        case .pickConvertTarget:
            apply(.chooseConvertSlot(index))
        case .normal:
            apply(.selectSlot(index))
        default:
            break
        }
    }

    func longPressSlot(_ index: Int) {
        guard interaction == .normal else { return }
        apply(.clearSlot(index))
    }

    func tapItem(_ index: Int) {
        guard interaction == .normal, state.inventory.indices.contains(index) else { return }
        switch state.inventory[index] {
        case .freeze:
            apply(.useItem(index, target: nil))
        case .repair:
            interaction = .pickRepairTarget(inventoryIndex: index)
        }
    }

    func cancelRepairTargeting() {
        if case .pickRepairTarget = interaction {
            interaction = .normal
        }
    }

    func chooseKind(_ kind: SlotKind) {
        guard case .pickKind(let choices) = interaction, choices.contains(kind) else { return }
        interaction = .pickInsertPosition(kind: kind)
    }

    func tapGap(_ position: Int) {
        guard case .pickInsertPosition(let kind) = interaction else { return }
        apply(.chooseAddSlot(kind: kind, position: position))
    }

    func end() {
        apply(.end)
    }

    // MARK: - 内部

    private func apply(_ action: RunAction) {
        let events = state.apply(action)
        handle(events)
        persist()
        refreshInteraction()
    }

    /// 待选队列决定交互模式；修键的目标选择由玩家发起，不受队列影响。
    private func refreshInteraction() {
        if case .pickRepairTarget = interaction { return }
        guard let choice = state.currentChoice, !isEnded else {
            if interaction.isChoice { interaction = .normal }
            return
        }
        switch choice {
        case .addSlot(let choices):
            if case .pickInsertPosition = interaction { return }
            if case .pickKind(let current) = interaction, current == choices { return }
            interaction = .pickKind(choices: choices)
        case .convertSlot(let kind):
            interaction = .pickConvertTarget(kind: kind)
        case .repairNow(let amount):
            interaction = .pickRepairNowTarget(amount: amount)
        }
    }

    private func handle(_ events: [RunEvent]) {
        for event in events {
            switch event {
            case .newPeak:
                peakPulse += 1
            case .thresholdCrossed(_, let reward):
                showToast(Self.text(for: reward))
                haptic(.success)
            case .keyDied:
                haptic(.warning)
            case .freezeStarted:
                haptic(.medium)
            case .rejected(.noEmptySlot):
                showToast(String(localized: "Slots are full. Tap a slot, then press a key to overwrite it."))
            case .rejected(.keyDead):
                haptic(.error)
            case .ended:
                pause()
                onEnded?(state)
            default:
                break
            }
        }
    }

    private func showToast(_ text: String) {
        toastCounter += 1
        toast = Toast(id: toastCounter, text: text)
        toastTask?.cancel()
        let id = toastCounter
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
        }
    }

    static func text(for reward: Reward) -> String {
        switch reward {
        case .unlockKeys(let defs):
            let symbols = defs.map(\.symbol.description).joined(separator: " ")
            return String(localized: "New key unlocked: \(symbols)")
        case .addSlot:
            return String(localized: "New slot! Pick a type and where to put it.")
        case .convertSlot(let kind):
            return String(localized: "Convert a slot to \(SlotKindInfo.name(kind)).")
        case .repair(let amount):
            return String(localized: "Repair kit +\(amount) added to your bag.")
        case .freeze(let seconds):
            return String(localized: "Freeze \(Int(seconds))s added to your bag.")
        }
    }

    private enum Haptic {
        case success, warning, error, medium
    }

    private func haptic(_ kind: Haptic) {
        guard hapticsEnabled else { return }
        switch kind {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}

/// 格子类型的名称与说明。
enum SlotKindInfo {
    static func name(_ kind: SlotKind) -> String {
        switch kind {
        case .normal: return String(localized: "Normal")
        case .stable: return String(localized: "Stable")
        case .echo: return String(localized: "Echo")
        case .amp: return String(localized: "Amp")
        case .rotten: return String(localized: "Rotten")
        }
    }

    static func detail(_ kind: SlotKind) -> String {
        switch kind {
        case .normal: return String(localized: "Digits rot at normal speed.")
        case .stable: return String(localized: "Never rots.")
        case .echo: return String(localized: "Mirrors the slot two to its left. Free, can't be filled directly.")
        case .amp: return String(localized: "Digits count double: 9 becomes 18.")
        case .rotten: return String(localized: "Rots twice as fast, but filling it costs no durability.")
        }
    }

    static func symbol(_ kind: SlotKind) -> String {
        switch kind {
        case .normal: return "square"
        case .stable: return "lock.fill"
        case .echo: return "arrow.turn.up.left"
        case .amp: return "bolt.fill"
        case .rotten: return "drop.triangle.fill"
        }
    }
}

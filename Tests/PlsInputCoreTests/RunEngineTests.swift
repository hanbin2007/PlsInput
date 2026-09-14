import Foundation
import Testing
@testable import PlsInputCore

@Suite("RunEngine")
struct RunEngineTests {
    // MARK: - 工具

    private func thresholds(_ texts: [String]) -> [BigNum] {
        texts.map { BigNum(threshold: $0)! }
    }

    private func puzzle(
        slots: [SlotKind] = [.normal, .normal, .normal, .normal, .normal],
        keys: [KeyDef] = [KeyDef(.digit(9), uses: 10), KeyDef(.pow, uses: 10)],
        rot: Double = 3,
        thresholds: [String] = [],
        rewards: [Reward] = [],
        cap: Double = 300
    ) -> DailyPuzzle {
        DailyPuzzle(
            seed: "test",
            slots: slots,
            keys: keys,
            rotInterval: rot,
            thresholds: self.thresholds(thresholds),
            rewards: rewards,
            runCapSeconds: cap
        )
    }

    private func key(_ state: RunState, _ symbol: KeySymbol) -> Int {
        state.keys.firstIndex { $0.symbol == symbol }!
    }

    private func press(_ state: inout RunState, _ symbol: KeySymbol) -> [RunEvent] {
        state.apply(.pressKey(key(state, symbol)))
    }

    // MARK: - 基本输入

    @Test func fillAndEvaluate() {
        var s = RunState(puzzle: puzzle())
        let e1 = press(&s, .digit(9))
        #expect(e1.contains(.started))
        #expect(e1.contains(.slotChanged(0)))
        #expect(e1.contains(.keyUsed(0, remaining: 9)))
        #expect(e1.contains(.valueChanged(BigNum(9))))
        #expect(e1.contains(.newPeak(BigNum(9))))
        #expect(s.phase == .running)

        let e2 = press(&s, .pow)
        #expect(e2.contains(.valueChanged(nil)))
        #expect(s.currentValue == nil)
        #expect(s.peak == BigNum(9))

        press(&s, .digit(9))
        #expect(s.currentValue == BigNum(387_420_489))
        #expect(s.peak == BigNum(387_420_489))
        #expect(s.keys[0].uses == 8)
        #expect(s.keys[1].uses == 9)
    }

    @Test func overwriteViaSelection() {
        var s = RunState(puzzle: puzzle())
        press(&s, .digit(9))
        press(&s, .pow)
        press(&s, .digit(9))
        s.apply(.selectSlot(1))
        #expect(s.selectedSlot == 1)
        press(&s, .digit(9))
        #expect(s.selectedSlot == nil)
        #expect(s.currentValue == BigNum(999))
        s.apply(.selectSlot(0))
        s.apply(.selectSlot(0))
        #expect(s.selectedSlot == nil)
    }

    @Test func clearSlotIsFree() {
        var s = RunState(puzzle: puzzle())
        press(&s, .digit(9))
        let before = s.keys[0].uses
        let events = s.apply(.clearSlot(0))
        #expect(events.contains(.slotChanged(0)))
        #expect(s.slots[0].content == .empty)
        #expect(s.keys[0].uses == before)
        #expect(s.currentValue == nil)
    }

    @Test func rejections() {
        var s = RunState(puzzle: puzzle(slots: [.normal], keys: [KeyDef(.digit(9), uses: 1)]))
        #expect(s.apply(.pressKey(5)) == [.rejected(.invalidIndex)])
        press(&s, .digit(9))
        #expect(s.keys[0].isDead)
        #expect(s.phase == .ended(.keysExhausted))
        #expect(s.apply(.pressKey(0)) == [.rejected(.ended)])

        var t = RunState(puzzle: puzzle(slots: [.normal], keys: [KeyDef(.digit(9), uses: 5)]))
        press(&t, .digit(9))
        #expect(press(&t, .digit(9)) == [.rejected(.noEmptySlot)])
    }

    // MARK: - 腐烂

    @Test func rotTiming() {
        var s = RunState(puzzle: puzzle(rot: 3))
        press(&s, .digit(9))
        s.tick(2.9)
        #expect(s.rottedDigit(at: 0) == 9)
        let events = s.tick(0.2)
        #expect(s.rottedDigit(at: 0) == 8)
        #expect(events.contains(.valueChanged(BigNum(8))))
        s.tick(100)
        #expect(s.rottedDigit(at: 0) == 0)
        #expect(s.currentValue == BigNum(0))
        #expect(s.peak == BigNum(9))
    }

    @Test func rotDoesNotRunBeforeStartOrAfterEnd() {
        var s = RunState(puzzle: puzzle())
        #expect(s.tick(10).isEmpty)
        #expect(s.rotClock == 0)
        press(&s, .digit(9))
        s.apply(.end)
        #expect(s.tick(10).isEmpty)
        #expect(s.rotClock == 0)
    }

    @Test func rottenSlotIsFreeButFast() {
        var s = RunState(puzzle: puzzle(slots: [.rotten, .normal], rot: 4))
        press(&s, .digit(9))
        #expect(s.keys[0].uses == 10)
        s.tick(2.1)
        #expect(s.rottedDigit(at: 0) == 8)
        press(&s, .digit(9))
        #expect(s.keys[0].uses == 9)
        s.tick(2)
        #expect(s.rottedDigit(at: 0) == 7)
        #expect(s.rottedDigit(at: 1) == 9)
    }

    @Test func stableSlotNeverRots() {
        var s = RunState(puzzle: puzzle(slots: [.stable, .normal], rot: 1))
        press(&s, .digit(9))
        press(&s, .digit(9))
        s.tick(50)
        #expect(s.rottedDigit(at: 0) == 9)
        #expect(s.rottedDigit(at: 1) == 0)
        #expect(s.currentValue == BigNum(90))
    }

    @Test func deadKeyCannotFillRottenSlot() {
        var s = RunState(puzzle: puzzle(slots: [.normal, .rotten], keys: [KeyDef(.digit(9), uses: 1), KeyDef(.pow, uses: 5)]))
        press(&s, .digit(9))
        #expect(s.keys[0].isDead)
        #expect(s.phase == .running)
        #expect(press(&s, .digit(9)) == [.rejected(.keyDead)])
    }

    // MARK: - 特殊格

    @Test func echoChainBuildsTower() {
        var s = RunState(puzzle: puzzle(slots: [.normal, .normal, .echo, .normal, .echo], rot: 3))
        press(&s, .digit(9))
        press(&s, .pow)
        press(&s, .pow)
        #expect(s.slots[3].content == .op(.pow))
        #expect(s.effectiveText(at: 2) == "9")
        #expect(s.effectiveText(at: 4) == "9")
        let nine = BigNum(9)
        #expect(s.currentValue == nine.power(nine.power(nine)))
        #expect(s.keys[0].uses == 9)
        s.tick(3)
        let eight = BigNum(8)
        #expect(s.currentValue == eight.power(eight.power(eight)))
        #expect(s.apply(.selectSlot(2)) == [.rejected(.echoSlot)])
        #expect(s.apply(.clearSlot(2)) == [.rejected(.echoSlot)])
    }

    @Test func echoOfEmptyIsEmpty() {
        var s = RunState(puzzle: puzzle(slots: [.echo, .normal, .echo]))
        #expect(s.effectiveToken(at: 0) == nil)
        press(&s, .digit(9))
        #expect(s.slots[1].content != .empty)
        #expect(s.effectiveToken(at: 2) == nil)
        #expect(s.currentValue == BigNum(9))
    }

    @Test func ampDoublesAndConcatenates() {
        var s = RunState(puzzle: puzzle(slots: [.normal, .amp, .normal], rot: 3))
        press(&s, .digit(9))
        press(&s, .digit(9))
        press(&s, .digit(9))
        #expect(s.effectiveText(at: 1) == "18")
        #expect(s.currentValue == BigNum(9189))
        s.tick(3)
        #expect(s.effectiveText(at: 1) == "16")
        #expect(s.currentValue == BigNum(8168))
    }

    // MARK: - 阈值与道具

    @Test func crossingSeveralTiersAtOnceAwardsInOrder() {
        let p = puzzle(
            keys: [KeyDef(.digit(9), uses: 10), KeyDef(.pow, uses: 10)],
            thresholds: ["1e3", "1e6", "1e12"],
            rewards: [.repair(amount: 8), .freeze(seconds: 10), .unlockKeys([KeyDef(.factorial, uses: 5)])]
        )
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        press(&s, .pow)
        let events = press(&s, .digit(9))
        #expect(events.contains(.thresholdCrossed(tier: 0, reward: .repair(amount: 8))))
        #expect(events.contains(.thresholdCrossed(tier: 1, reward: .freeze(seconds: 10))))
        #expect(!events.contains { if case .thresholdCrossed(let t, _) = $0 { return t == 2 } else { return false } })
        #expect(s.crossedTiers == 2)
        #expect(s.inventory == [.repair(amount: 8), .freeze(seconds: 10)])
        #expect(s.nextThreshold == BigNum(threshold: "1e12"))

        press(&s, .pow)
        let e2 = press(&s, .digit(9))
        #expect(e2.contains(.keysUnlocked([KeyDef(.factorial, uses: 5)])))
        #expect(s.keys.map(\.symbol) == [.digit(9), .pow, .factorial])
        #expect(s.crossedTiers == 3)
        #expect(s.nextThreshold == nil)

        // 再跨一次不重复发放
        s.apply(.clearSlot(4))
        press(&s, .digit(9))
        #expect(s.crossedTiers == 3)
    }

    @Test func unlockExistingKeyMergesUses() {
        let p = puzzle(thresholds: ["1e3"], rewards: [.unlockKeys([KeyDef(.pow, uses: 4)])])
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        press(&s, .pow)
        press(&s, .digit(9))
        #expect(s.keys.count == 2)
        #expect(s.keys[1].uses == 9 + 4)
    }

    @Test func addSlotChoiceFlow() {
        let p = puzzle(slots: [.normal, .normal, .normal], thresholds: ["1e3"], rewards: [.addSlot(choices: [.echo, .stable])])
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        press(&s, .pow)
        let events = press(&s, .digit(9))
        #expect(events.contains(.choiceRequired(.addSlot(choices: [.echo, .stable]))))
        #expect(s.currentChoice == .addSlot(choices: [.echo, .stable]))
        // 待选期间时钟不走，按键被拒
        #expect(s.tick(5).isEmpty)
        #expect(s.rotClock == 0)
        #expect(press(&s, .digit(9)) == [.rejected(.choicePending)])
        #expect(s.apply(.chooseAddSlot(kind: .amp, position: 0)) == [.rejected(.badChoice)])
        #expect(s.apply(.chooseAddSlot(kind: .echo, position: 9)) == [.rejected(.invalidIndex)])
        let chosen = s.apply(.chooseAddSlot(kind: .echo, position: 3))
        #expect(chosen.contains(.slotAdded(3, .echo)))
        #expect(s.slots.map(\.kind) == [.normal, .normal, .normal, .echo])
        #expect(s.pendingChoices.isEmpty)
        // 回声格接在 9^9 后面：9 ^ 9 [echo=^] 不合法
        #expect(s.currentValue == nil)
        s.apply(.selectSlot(1))
        #expect(s.selectedSlot == 1)
    }

    @Test func convertSlotRebasesDigit() {
        let p = puzzle(slots: [.normal, .normal], rot: 3, thresholds: ["10"], rewards: [.convertSlot(.stable)])
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        s.tick(3.5)
        #expect(s.rottedDigit(at: 0) == 8)
        // 触发阈值：9 → 98
        press(&s, .digit(9))
        #expect(s.currentChoice == .convertSlot(.stable))
        s.apply(.chooseConvertSlot(0))
        #expect(s.slots[0].kind == .stable)
        #expect(s.rottedDigit(at: 0) == 8)
        s.tick(100)
        #expect(s.rottedDigit(at: 0) == 8)
        #expect(s.rottedDigit(at: 1) == 0)
    }

    @Test func convertToEchoDropsContent() {
        let p = puzzle(slots: [.normal, .normal, .normal], thresholds: ["10"], rewards: [.convertSlot(.echo)])
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        press(&s, .digit(9))
        s.apply(.chooseConvertSlot(2))
        #expect(s.slots[2].kind == .echo)
        #expect(s.slots[2].content == .empty)
        #expect(s.effectiveText(at: 2) == "9")
        #expect(s.currentValue == BigNum(999))
    }

    @Test func inventoryFullRules() {
        let p = puzzle(
            thresholds: ["10", "100", "1000", "1e4", "5e4"],
            rewards: [.repair(amount: 1), .repair(amount: 2), .repair(amount: 3), .freeze(seconds: 7), .repair(amount: 4)]
        )
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        press(&s, .digit(9))
        press(&s, .digit(9))
        press(&s, .digit(9))
        #expect(s.inventory.count == 3)
        let events = press(&s, .digit(9))
        #expect(events.contains(.freezeStarted(7)))
        #expect(s.freezeRemaining == 7)
        #expect(s.currentChoice == .repairNow(amount: 4))
        let before = s.keys[0].uses
        s.apply(.chooseRepairNow(keyIndex: 0))
        #expect(s.keys[0].uses == before + 4)
        #expect(s.pendingChoices.isEmpty)
    }

    @Test func useItems() {
        let p = puzzle(keys: [KeyDef(.digit(9), uses: 2)], thresholds: ["1"], rewards: [.repair(amount: 8)])
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        #expect(s.inventory == [.repair(amount: 8)])
        #expect(s.apply(.useItem(0, target: nil)) == [.rejected(.needsTarget)])
        #expect(s.apply(.useItem(3, target: 0)) == [.rejected(.invalidIndex)])
        s.apply(.useItem(0, target: 0))
        // 修键只能修回初始上限：1 + 8 封顶到 2
        #expect(s.keys[0].uses == 2)
        #expect(s.keys[0].maxUses == 2)
        #expect(s.inventory.isEmpty)
    }

    @Test func repairIsCappedAtInitialDurability() {
        let p = puzzle(
            keys: [KeyDef(.digit(9), uses: 4), KeyDef(.pow, uses: 5)],
            thresholds: ["1", "10", "100", "1000"],
            rewards: [.repair(amount: 8), .repair(amount: 8), .repair(amount: 8), .repair(amount: 8)]
        )
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        // 满耐久的键不能修，道具不消耗
        #expect(s.apply(.useItem(0, target: 1)) == [.rejected(.keyAlreadyFull)])
        #expect(s.inventory.count == 1)
        press(&s, .digit(9))
        press(&s, .digit(9))
        #expect(s.inventory.count == 3)
        // 第四次按键：9999 跨 T4，背包已满，9 键刚好报废，必须立即修
        press(&s, .digit(9))
        #expect(s.keys[0].isDead)
        #expect(s.crossedTiers == 4)
        #expect(s.currentChoice == .repairNow(amount: 8))
        #expect(s.apply(.chooseRepairNow(keyIndex: 1)) == [.rejected(.keyAlreadyFull)])
        s.apply(.chooseRepairNow(keyIndex: 0))
        // 0 + 8 封顶到初始的 4
        #expect(s.keys[0].uses == 4)
        #expect(s.pendingChoices.isEmpty)
        #expect(s.apply(.useItem(0, target: 0)) == [.rejected(.keyAlreadyFull)])
    }

    @Test func repairIsWastedWhenNothingToRepair() {
        // 全是烂格：按键不耗耐久，键始终满；背包装满三个修键后，第四个作废
        let p = puzzle(
            slots: [.rotten, .rotten, .rotten, .rotten],
            keys: [KeyDef(.digit(9), uses: 5)],
            thresholds: ["1", "10", "100", "1000"],
            rewards: [.repair(amount: 8), .repair(amount: 8), .repair(amount: 8), .repair(amount: 8)]
        )
        var s = RunState(puzzle: p)
        press(&s, .digit(9)); press(&s, .digit(9)); press(&s, .digit(9))
        #expect(s.inventory.count == 3)
        #expect(s.keys[0].isFull)
        #expect(s.apply(.useItem(0, target: 0)) == [.rejected(.keyAlreadyFull)])
        let events = press(&s, .digit(9))
        #expect(events.contains(.rewardWasted(.repair(amount: 8))))
        #expect(s.inventory.count == 3)
        #expect(s.pendingChoices.isEmpty)
        #expect(s.crossedTiers == 4)
    }

    @Test func unlockingExistingKeyRaisesCap() {
        let p = puzzle(thresholds: ["1e3"], rewards: [.unlockKeys([KeyDef(.pow, uses: 4)])])
        var s = RunState(puzzle: p)
        press(&s, .digit(9)); press(&s, .pow); press(&s, .digit(9))
        #expect(s.keys[1].uses == 9 + 4)
        #expect(s.keys[1].maxUses == 10 + 4)
    }

    @Test func freezePausesRotClock() {
        let p = puzzle(rot: 1, thresholds: ["1"], rewards: [.freeze(seconds: 10)])
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        s.apply(.useItem(0, target: nil))
        #expect(s.isFrozen)
        s.tick(4)
        #expect(s.rotClock == 0)
        #expect(s.freezeRemaining == 6)
        let events = s.tick(8)
        #expect(events.contains(.freezeEnded))
        #expect(s.freezeRemaining == 0)
        #expect(abs(s.rotClock - 2) < 1e-9)
        #expect(s.rottedDigit(at: 0) == 7)
    }

    // MARK: - 结束

    @Test func keysExhaustedWaitsForRepair() {
        let p = puzzle(keys: [KeyDef(.digit(9), uses: 2)], thresholds: ["1"], rewards: [.repair(amount: 3)])
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        press(&s, .digit(9))
        #expect(s.allKeysDead)
        #expect(s.phase == .running)
        s.apply(.useItem(0, target: 0))
        // 修回上限 2，再按两次就耗尽
        #expect(s.keys[0].uses == 2)
        press(&s, .digit(9))
        let events = press(&s, .digit(9))
        #expect(events.contains(.ended(.keysExhausted)))
        #expect(s.phase == .ended(.keysExhausted))
    }

    @Test func timeCapEndsRun() {
        var s = RunState(puzzle: puzzle(cap: 30))
        press(&s, .digit(9))
        let events = s.tick(31)
        #expect(events.contains(.ended(.timeCap)))
        #expect(s.rotClock == 30)
        #expect(s.phase == .ended(.timeCap))
    }

    @Test func playerEndClearsPendingChoices() {
        let p = puzzle(thresholds: ["1"], rewards: [.addSlot(choices: [.normal])])
        var s = RunState(puzzle: p)
        press(&s, .digit(9))
        #expect(s.currentChoice != nil)
        let events = s.apply(.end)
        #expect(events == [.ended(.playerEnded)])
        #expect(s.pendingChoices.isEmpty)
    }

    // MARK: - 确定性与存档

    @Test func replayIsDeterministicAndSurvivesEncoding() throws {
        let p = puzzle(
            slots: [.normal, .amp, .echo, .normal, .rotten],
            keys: [KeyDef(.digit(9), uses: 6), KeyDef(.digit(3), uses: 6), KeyDef(.pow, uses: 4)],
            rot: 2,
            thresholds: ["1e3", "1e6", "1e12"],
            rewards: [.freeze(seconds: 3), .addSlot(choices: [.stable, .echo]), .repair(amount: 2)]
        )
        let script: [(Double, RunAction?)] = [
            (0, .pressKey(0)), (0.5, .pressKey(2)), (0.5, .pressKey(0)), (1.2, .pressKey(2)),
            (0.3, .pressKey(1)), (0, .chooseAddSlot(kind: .echo, position: 5)), (2.5, .useItem(0, target: nil)),
            (3, .selectSlot(0)), (0, .pressKey(0)), (4, .clearSlot(3)), (1, .pressKey(1)), (6, nil), (0, .end),
        ]

        func run(_ p: DailyPuzzle, encodeAfter: Int?) throws -> (RunState, [RunEvent]) {
            var s = RunState(puzzle: p)
            var all: [RunEvent] = []
            for (i, step) in script.enumerated() {
                all += s.tick(step.0)
                if let a = step.1 { all += s.apply(a) }
                if encodeAfter == i {
                    let data = try JSONEncoder().encode(s)
                    s = try JSONDecoder().decode(RunState.self, from: data)
                }
            }
            return (s, all)
        }

        let (a, ea) = try run(p, encodeAfter: nil)
        let (b, eb) = try run(p, encodeAfter: 4)
        let (c, ec) = try run(p, encodeAfter: 9)
        #expect(a == b)
        #expect(a == c)
        #expect(ea == eb)
        #expect(ea == ec)
        #expect(a.phase == .ended(.playerEnded))
        #expect(a.peak > BigNum(1e3))
    }
}

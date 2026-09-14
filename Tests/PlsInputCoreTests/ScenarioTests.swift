import Testing
@testable import PlsInputCore

/// 端到端场景：用当天真实种子跑一遍关键交互，作为回归。
@Suite("Scenario")
struct ScenarioTests {
    @Test func seed20260915RewardFlow() {
        let p = PuzzleGenerator.generate(seed: "PlsInput-v1-2026-09-15")
        var s = RunState(puzzle: p)
        let five = p.keys.firstIndex { $0.symbol == .digit(5) }!
        let pow = p.keys.firstIndex { $0.symbol == .pow }!

        // 5 ^ 5 5 → 5^55 ≈ 2.8e38，跨过前四档阈值。
        s.apply(.pressKey(five))
        s.apply(.pressKey(pow))
        s.apply(.pressKey(five))
        s.apply(.pressKey(five))
        #expect(s.currentValue == BigNum(5).power(BigNum(55)))
        #expect(s.crossedTiers == 4)

        // 第 2 档是改格为增幅：把末位 5 变 10 → 5^510，跨过第 5 档冻结。
        #expect(s.currentChoice == .convertSlot(.amp))
        s.apply(.chooseConvertSlot(3))
        #expect(s.currentValue == BigNum(5).power(BigNum(510)))
        #expect(s.inventory.contains(.freeze(seconds: 10)))

        // 第 3、4 档是加格，逐个消化。
        #expect(s.pendingChoices.count == 2)
        s.apply(.chooseAddSlot(kind: .stable, position: 4))
        s.apply(.chooseAddSlot(kind: .rotten, position: 5))
        #expect(s.pendingChoices.isEmpty)
        #expect(s.slots.count == 6)
        #expect(s.peak == BigNum(5).power(BigNum(510)))
    }
}

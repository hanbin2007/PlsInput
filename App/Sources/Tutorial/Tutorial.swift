import Foundation
import Observation
import PlsInputCore

/// 教程用的固定题：慢腐烂，四档奖励依次演示解锁键、加格、冻结、修键。
enum TutorialPuzzle {
    static func make() -> DailyPuzzle {
        DailyPuzzle(
            seed: "PlsInput-tutorial",
            slots: [.normal, .normal, .normal, .normal],
            keys: [KeyDef(.digit(3), uses: 6), KeyDef(.digit(9), uses: 16), KeyDef(.plus, uses: 6)],
            rotInterval: 6,
            thresholds: ["1e3", "1e6", "1e100", "1e200"].map { BigNum(threshold: $0)! },
            rewards: [
                .unlockKeys([KeyDef(.pow, uses: 6)]),
                .addSlot(choices: [.stable, .amp]),
                .freeze(seconds: 10),
                .repair(amount: 8),
            ],
            runCapSeconds: 3600
        )
    }
}

/// 逐步引导：手动步骤点"继续"，自动步骤在状态满足条件时前进。
@MainActor
@Observable
final class TutorialController {
    struct Step {
        var text: String
        var focus: GameFocus?
        var manual: Bool
        var done: @MainActor (GameViewModel, Double) -> Bool
    }

    let game: GameViewModel
    let steps: [Step]
    private(set) var index = 0
    private(set) var stepStartClock: Double = 0

    init(game: GameViewModel) {
        self.game = game
        steps = Self.makeSteps()
    }

    var isFinished: Bool { index >= steps.count }
    var isLastStep: Bool { index == steps.count - 1 }
    var current: Step? { isFinished ? nil : steps[index] }

    var coach: CoachMark? {
        guard let step = current else { return nil }
        return CoachMark(
            text: step.text,
            showsContinue: step.manual,
            continueTitle: isLastStep ? String(localized: "Done") : String(localized: "Continue")
        )
    }

    func advance() {
        guard !isFinished else { return }
        index += 1
        stepStartClock = game.state.rotClock
    }

    func advanceIfManual() {
        if current?.manual == true { advance() }
    }

    /// 状态或交互变化时调用。
    func check() {
        guard let step = current, !step.manual else { return }
        if step.done(game, stepStartClock) { advance() }
    }

    private static func makeSteps() -> [Step] {
        let never: @MainActor (GameViewModel, Double) -> Bool = { _, _ in false }
        return [
            Step(
                text: String(localized: "Goal: build the biggest number you can. Everything else is a means to that."),
                focus: .display, manual: true, done: never
            ),
            Step(
                text: String(localized: "Press 9."),
                focus: .keyboard, manual: false,
                done: { game, _ in !game.state.slots[0].content.isEmpty }
            ),
            Step(
                text: String(localized: "Two more 9s. Make it 999."),
                focus: .keyboard, manual: false,
                done: { game, _ in (game.state.currentValue ?? .zero) >= BigNum(999) }
            ),
            Step(
                text: String(localized: "Digits rot. Watch the red bar under a slot and wait for a digit to drop."),
                focus: .slots, manual: false,
                done: { game, _ in
                    game.state.slots.indices.contains { i in
                        if case .digit(let base, _) = game.state.slots[i].content, let now = game.state.rottedDigit(at: i) {
                            return now < base
                        }
                        return false
                    }
                }
            ),
            Step(
                text: String(localized: "Save it: tap the rotted slot, then press 9. Overwriting costs one press of durability."),
                focus: .slots, manual: false,
                done: { game, start in
                    game.state.slots.contains { slot in
                        if case .digit(_, let placedAt) = slot.content { return placedAt > start }
                        return false
                    }
                }
            ),
            Step(
                text: String(localized: "Every key shows how many presses it has left. At 0 the key breaks. Repair kits bring it back."),
                focus: .keyboard, manual: true, done: never
            ),
            Step(
                text: String(localized: "Cross 1,000 to earn a reward. Press one more 9."),
                focus: .ladder, manual: false,
                done: { game, _ in game.state.crossedTiers >= 1 }
            ),
            Step(
                text: String(localized: "You unlocked ^. Tap the second slot, then press ^ to turn 9999 into 9^99."),
                focus: .keyboard, manual: false,
                done: { game, _ in game.state.crossedTiers >= 2 || game.interaction.isChoice }
            ),
            Step(
                text: String(localized: "A new slot! Choose a type. Rot is paused while you decide."),
                focus: nil, manual: false,
                done: { game, _ in
                    if case .pickInsertPosition = game.interaction { return true }
                    return game.state.slots.count >= 5
                }
            ),
            Step(
                text: String(localized: "Now tap a gap to place it. Position matters: next to ^ it becomes part of the exponent."),
                focus: .slots, manual: false,
                done: { game, _ in game.state.slots.count >= 5 }
            ),
            Step(
                text: String(localized: "Fill it with 9. Three digits in the exponent are astronomically more than two."),
                focus: .keyboard, manual: false,
                done: { game, _ in game.state.crossedTiers >= 4 }
            ),
            Step(
                text: String(localized: "Two items landed in your bag. Tap Freeze to pause rot for 10 seconds."),
                focus: .bag, manual: false,
                done: { game, _ in game.state.isFrozen }
            ),
            Step(
                text: String(localized: "Slot types: Stable never rots. Echo copies the slot two to its left. Amp doubles a digit. Rotten rots fast but costs no durability."),
                focus: .slots, manual: true, done: never
            ),
            Step(
                text: String(localized: "That's the game. One puzzle a day, one attempt, everyone on the same keyboard. Your peak is your score."),
                focus: nil, manual: true, done: never
            ),
        ]
    }
}

import SwiftUI
import PlsInputCore

/// 对局页。结束后由容器切换到结果页。
struct GameContainerView: View {
    var model: GameViewModel

    var body: some View {
        if model.mode == .tutorial {
            TutorialView(game: model)
        } else if model.isEnded {
            ResultView(model: model)
        } else {
            GameView(model: model)
        }
    }
}

/// 教程用：把注意力引到某个区域，其余区域压暗。
enum GameFocus: Equatable {
    case display
    case slots
    case bag
    case ladder
    case keyboard
}

/// 教程气泡。
struct CoachMark: Equatable {
    var text: String
    var showsContinue: Bool
    var continueTitle: String = String(localized: "Continue")
}

struct GameView: View {
    var model: GameViewModel
    var focus: GameFocus? = nil
    var coach: CoachMark? = nil
    var onCoachContinue: (() -> Void)? = nil
    var hideEnd = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmEnd = false
    @State private var showRules = false

    var body: some View {
        ZStack(alignment: .top) {
            Palette.background.ignoresSafeArea()
            FrostOverlay(active: model.state.isFrozen)
            VStack(spacing: 14) {
                topBar
                DisplayPanel(model: model)
                    .dimmed(unless: .display, focus: focus)
                SlotRowView(model: model)
                    .dimmed(unless: .slots, focus: focus)
                InteractionHint(model: model)
                    .dimmed(unless: .slots, focus: focus)
                InventoryBar(model: model)
                    .dimmed(unless: .bag, focus: focus)
                ThresholdLadder(model: model)
                    .padding(.top, 4)
                    .dimmed(unless: .ladder, focus: focus)
                Spacer(minLength: 0)
                if let coach {
                    CoachBubble(mark: coach, onContinue: onCoachContinue)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                        .id(coach.text)
                    Spacer(minLength: 0)
                }
                KeyboardView(model: model)
                    .dimmed(unless: .keyboard, focus: focus)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            FlashOverlay(trigger: model.thresholdPulse)

            if let toast = model.toast {
                ToastView(text: toast.text)
                    .id(toast.id)
                    .padding(.top, 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if case .pickKind(let choices) = model.interaction {
                KindPickerOverlay(choices: choices) { model.chooseKind($0) }
                    .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: model.toast)
        .animation(Motion.snappy, value: model.interaction)
        .animation(Motion.settle, value: coach)
        .onAppear { model.resume() }
        .onDisappear { model.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.resume()
            } else {
                model.pause()
            }
        }
        .alert(String(localized: "End this run?"), isPresented: $confirmEnd) {
            Button(String(localized: "End"), role: .destructive) { model.end() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Your peak so far becomes your score.")
        }
        .sheet(isPresented: $showRules) {
            RulesView()
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
            if !hideEnd {
                Button {
                    confirmEnd = true
                } label: {
                    Text("End")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.dim)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Palette.panel))
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                Color.clear.frame(width: 56, height: 30)
            }
            Spacer()
            if let next = model.nextThresholdText {
                VStack(spacing: 1) {
                    Text("Next reward at")
                        .font(.caption2)
                        .foregroundStyle(Palette.dim)
                    Text(next)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                }
            } else {
                Text("All rewards claimed")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
            Spacer()
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    if model.state.isFrozen {
                        Image(systemName: "snowflake")
                            .foregroundStyle(Palette.freeze)
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        Text("\(Int(model.state.freezeRemaining.rounded(.up)))s")
                            .foregroundStyle(Palette.freeze)
                            .contentTransition(.numericText(countsDown: true))
                    } else {
                        Image(systemName: "timer")
                            .foregroundStyle(Palette.dim)
                        Text(model.clockText)
                            .foregroundStyle(Palette.dim)
                            .contentTransition(.numericText())
                    }
                }
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 58, alignment: .trailing)
                .animation(Motion.snappy, value: model.state.isFrozen)
                Button {
                    showRules = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Palette.dim)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Palette.panel))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }
}

// MARK: - 焦点压暗

private extension View {
    func dimmed(unless region: GameFocus, focus: GameFocus?) -> some View {
        opacity(focus == nil || focus == region ? 1 : 0.3)
            .animation(.easeOut(duration: 0.25), value: focus)
    }
}

// MARK: - 显示区

struct DisplayPanel: View {
    var model: GameViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bump = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(model.displayText)
                    .font(.system(size: 50, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .foregroundStyle(model.state.currentValue == nil ? Palette.dim : Palette.text)
                    .contentTransition(.numericText())
                    .glow(Palette.accent, strength: model.magnitude)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(bump ? 1.04 : 1)
                HStack(spacing: 6) {
                    Text("Peak")
                        .font(.caption)
                        .foregroundStyle(Palette.dim)
                    Text(model.peakText)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 14)
        }
        .overlay {
            BurstView(trigger: model.thresholdPulse, color: Palette.accent, count: 22, radius: 120)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Palette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            model.state.isFrozen ? Palette.freeze.opacity(0.8) : Palette.accent.opacity(0.35 * model.magnitude),
                            lineWidth: model.state.isFrozen ? 2 : 1.5
                        )
                )
        )
        .animation(Motion.settle, value: model.displayText)
        .animation(.easeOut(duration: 0.3), value: model.magnitude)
        .onChange(of: model.peakPulse) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.spring(duration: 0.16, bounce: 0)) { bump = true }
            Task {
                try? await Task.sleep(for: .milliseconds(160))
                withAnimation(.spring(duration: 0.24, bounce: 0.15)) { bump = false }
            }
        }
    }
}

// MARK: - 格子

struct SlotRowView: View {
    var model: GameViewModel

    private var isInserting: Bool {
        if case .pickInsertPosition = model.interaction { return true }
        return false
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isInserting ? 2 : 6) {
                ForEach(Array(model.state.slots.enumerated()), id: \.element.id) { index, slot in
                    gap(at: index)
                    SlotTile(model: model, index: index, slot: slot)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                gap(at: model.state.slots.count)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .animation(Motion.settle, value: model.state.slots.map(\.id))
            .animation(Motion.snappy, value: isInserting)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: 78)
    }

    @ViewBuilder
    private func gap(at position: Int) -> some View {
        if isInserting {
            Button {
                model.tapGap(position)
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 26, height: 66)
            }
            .buttonStyle(PressableButtonStyle())
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        } else {
            Color.clear.frame(width: 0, height: 66)
        }
    }
}

struct SlotTile: View {
    var model: GameViewModel
    let index: Int
    let slot: Slot

    var body: some View {
        let text = model.state.effectiveText(at: index)
        let digitValue = text.flatMap(Int.init)
        let selected = model.state.selectedSlot == index
        let convertTarget: Bool = {
            if case .pickConvertTarget = model.interaction { return true }
            return false
        }()
        let border = selected ? Palette.accent : (convertTarget ? Palette.accent.opacity(0.6) : Palette.color(for: slot.kind))

        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10)
                .fill(slot.kind == .rotten ? Palette.rotten.opacity(0.18) : Palette.tile)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(border, style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5, dash: slot.kind == .echo ? [4, 3] : []))
                )
            Text(text ?? "")
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(digitValue == nil ? Palette.text : Palette.digitColor(digitValue))
                .opacity(slot.kind == .echo ? 0.75 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.snappy, value: text)
            if slot.kind != .normal {
                Image(systemName: SlotKindInfo.symbol(slot.kind))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.color(for: slot.kind))
                    .padding(4)
            }
            if let progress = model.decayProgress(at: index) {
                VStack {
                    Spacer()
                    GeometryReader { geo in
                        Capsule()
                            .fill(Palette.danger.opacity(0.75))
                            .frame(width: max(2, geo.size.width * progress), height: 3)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 5)
                }
            }
        }
        .frame(width: 54, height: 66)
        .scaleEffect(selected ? 1.06 : 1)
        .shake(on: model.slotShake[slot.id] ?? 0, amount: 3)
        .contentShape(Rectangle())
        .onTapGesture { model.tapSlot(index) }
        .onLongPressGesture(minimumDuration: 0.45) { model.longPressSlot(index) }
        .animation(Motion.snappy, value: selected)
    }
}

// MARK: - 提示与背包

struct InteractionHint: View {
    var model: GameViewModel

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(model.interaction == .normal ? Palette.dim : Palette.accent)
            .frame(maxWidth: .infinity, minHeight: 18)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: text)
    }

    private var text: String {
        switch model.interaction {
        case .normal:
            if model.state.selectedSlot != nil {
                return String(localized: "Slot selected. Press a key to overwrite it, or tap it again to deselect.")
            }
            return String(localized: "Long-press a slot to clear it.")
        case .pickRepairTarget:
            return String(localized: "Tap a key to repair it.")
        case .pickKind:
            return String(localized: "Choose the new slot's type.")
        case .pickInsertPosition(let kind):
            return String(localized: "Tap a gap to place the \(SlotKindInfo.name(kind)) slot.")
        case .pickConvertTarget(let kind):
            return String(localized: "Tap a slot to convert it to \(SlotKindInfo.name(kind)).")
        case .pickRepairNowTarget(let amount):
            return String(localized: "Bag is full. Tap a key to repair it now (+\(amount)).")
        }
    }
}

struct InventoryBar: View {
    var model: GameViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.state.inventory.enumerated()), id: \.offset) { index, item in
                Button {
                    model.tapItem(index)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon(for: item))
                        Text(label(for: item))
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Palette.tileRaised))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(model.interaction != .normal)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            if model.state.inventory.isEmpty {
                Text("Bag is empty")
                    .font(.footnote)
                    .foregroundStyle(Palette.dim.opacity(0.7))
                    .transition(.opacity)
            }
            Spacer()
            if case .pickRepairTarget = model.interaction {
                Button(String(localized: "Cancel")) { model.cancelRepairTargeting() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .transition(.opacity)
            }
        }
        .frame(height: 36)
        .animation(Motion.settle, value: model.state.inventory)
    }

    private func icon(for item: Item) -> String {
        switch item {
        case .repair: return "wrench.and.screwdriver.fill"
        case .freeze: return "snowflake"
        }
    }

    private func label(for item: Item) -> String {
        switch item {
        case .repair(let amount): return String(localized: "Repair +\(amount)")
        case .freeze(let seconds): return String(localized: "Freeze \(Int(seconds))s")
        }
    }
}

// MARK: - 键盘

struct KeyboardView: View {
    var model: GameViewModel

    private var isRepairTargeting: Bool {
        switch model.interaction {
        case .pickRepairTarget, .pickRepairNowTarget: return true
        default: return false
        }
    }

    var body: some View {
        let count = model.state.keys.count
        let columnCount = count <= 4 ? max(count, 1) : (count <= 6 ? 3 : 4)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(model.state.keys.enumerated()), id: \.element.symbol) { index, key in
                KeyCap(
                    key: key,
                    highlighted: isRepairTargeting && !key.isFull,
                    enabled: isRepairTargeting ? !key.isFull : (!key.isDead && !model.interaction.isChoice),
                    shakeTrigger: model.keyShake[index] ?? 0
                ) {
                    model.pressKey(index)
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: model.state.keys.map(\.symbol))
    }
}

struct KeyCap: View {
    let key: KeyState
    let highlighted: Bool
    let enabled: Bool
    var shakeTrigger: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(key.isDead ? Palette.panel : Palette.tileRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(highlighted ? Palette.accent : Color.white.opacity(0.06), lineWidth: highlighted ? 2 : 1)
                    )
                    .overlay(alignment: .top) {
                        // 键帽顶部一条高光，像真的按键
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: [Color.white.opacity(key.isDead ? 0.02 : 0.07), .clear], startPoint: .top, endPoint: .center))
                    }
                Text(key.symbol.description)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(key.isDead ? Palette.dim.opacity(0.5) : Palette.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("\(max(key.uses, 0))")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(key.uses <= 2 ? Palette.danger : Palette.dim)
                    .contentTransition(.numericText(countsDown: true))
                    .padding(6)
            }
            .frame(height: 72)
        }
        .buttonStyle(KeyCapButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .shake(on: shakeTrigger, amount: 6)
        .animation(Motion.snappy, value: key.uses)
        .animation(.easeOut(duration: 0.2), value: enabled)
    }
}

struct KeyCapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// 通用按压反馈：按下即缩到 0.97。
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 阈值阶梯

struct ThresholdLadder: View {
    var model: GameViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let thresholds = model.state.puzzle.thresholds
        let crossed = model.state.crossedTiers
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(thresholds.indices, id: \.self) { i in
                    let reached = i < crossed
                    let isNext = i == crossed
                    let isLatest = i == crossed - 1
                    ZStack {
                        Capsule()
                            .fill(reached ? Palette.accent : (isNext ? Palette.accent.opacity(0.18) : Palette.panel))
                            .overlay(Capsule().strokeBorder(isNext ? Palette.accent : Color.clear, lineWidth: 1.5))
                        if reached {
                            Image(systemName: rewardSymbol(model.state.puzzle.rewards[i]))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Palette.background)
                                .symbolEffect(.bounce, value: isLatest ? model.thresholdPulse : 0)
                        } else {
                            Text(isNext ? "\(i + 1)" : "·")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(isNext ? Palette.accent : Palette.dim.opacity(0.6))
                        }
                    }
                    .frame(height: 22)
                    .glow(Palette.accent, strength: isLatest && !reduceMotion ? 0.5 : 0)
                    .scaleEffect(isLatest ? 1.08 : 1)
                }
            }
            .animation(Motion.bouncy, value: crossed)
            HStack {
                Text(String(localized: "Rewards \(crossed) / \(thresholds.count)"))
                    .contentTransition(.numericText())
                Spacer()
                if let next = model.nextThresholdText {
                    Text(String(localized: "Next at \(next)"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Palette.dim)
            .animation(Motion.snappy, value: crossed)
        }
        .padding(.horizontal, 2)
    }

    private func rewardSymbol(_ reward: Reward) -> String {
        switch reward {
        case .unlockKeys: return "keyboard"
        case .addSlot: return "plus"
        case .convertSlot: return "arrow.triangle.2.circlepath"
        case .repair: return "wrench.and.screwdriver.fill"
        case .freeze: return "snowflake"
        }
    }
}

// MARK: - 覆盖层

struct KindPickerOverlay: View {
    let choices: [SlotKind]
    let onPick: (SlotKind) -> Void
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text("New slot! Choose its type")
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                ForEach(Array(choices.enumerated()), id: \.element) { index, kind in
                    Button {
                        onPick(kind)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: SlotKindInfo.symbol(kind))
                                .font(.title3)
                                .foregroundStyle(Palette.color(for: kind))
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SlotKindInfo.name(kind))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Palette.text)
                                Text(SlotKindInfo.detail(kind))
                                    .font(.footnote)
                                    .foregroundStyle(Palette.dim)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.tile))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .staggeredAppear(index: index + 1)
                }
                Text("Rot is paused while you choose.")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Palette.panel))
            .padding(24)
            .scaleEffect(shown ? 1 : 0.95)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Motion.settle) { shown = true } }
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Palette.background)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Capsule().fill(Palette.accent))
            .padding(.horizontal, 24)
    }
}

/// 冻结时的冰霜边缘。
struct FrostOverlay: View {
    var active: Bool

    var body: some View {
        RadialGradient(
            colors: [.clear, Palette.freeze.opacity(0.22)],
            center: .center,
            startRadius: 120,
            endRadius: 520
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(active ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: active)
    }
}

/// 教程气泡。
struct CoachBubble: View {
    var mark: CoachMark
    var onContinue: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Palette.accent)
                    .font(.headline)
                Text(mark.text)
                    .font(.subheadline)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mark.showsContinue {
                Button(action: { onContinue?() }) {
                    Text(mark.continueTitle)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accent))
                        .foregroundStyle(Palette.background)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Palette.panel)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent.opacity(0.5), lineWidth: 1))
        )
    }
}

import SwiftUI
import PlsInputCore

/// 对局页。结束后由容器切换到结果页。
struct GameContainerView: View {
    var model: GameViewModel

    var body: some View {
        if model.isEnded {
            ResultView(model: model)
        } else {
            GameView(model: model)
        }
    }
}

struct GameView: View {
    var model: GameViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmEnd = false

    var body: some View {
        ZStack(alignment: .top) {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 14) {
                topBar
                DisplayPanel(model: model)
                SlotRowView(model: model)
                InteractionHint(model: model)
                InventoryBar(model: model)
                Spacer(minLength: 0)
                KeyboardView(model: model)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

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
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .animation(.easeOut(duration: 0.2), value: model.interaction)
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
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack {
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
                }
            } else {
                Text("All rewards claimed")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
            Spacer()
            HStack(spacing: 4) {
                if model.state.isFrozen {
                    Image(systemName: "snowflake")
                        .foregroundStyle(Palette.freeze)
                    Text("\(Int(model.state.freezeRemaining.rounded(.up)))s")
                        .foregroundStyle(Palette.freeze)
                } else {
                    Image(systemName: "timer")
                        .foregroundStyle(Palette.dim)
                    Text(model.clockText)
                        .foregroundStyle(Palette.dim)
                }
            }
            .font(.subheadline.monospacedDigit())
            .frame(minWidth: 64, alignment: .trailing)
        }
    }
}

struct DisplayPanel: View {
    var model: GameViewModel
    @State private var bump = false

    var body: some View {
        VStack(spacing: 6) {
            Text(model.displayText)
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.3)
                .lineLimit(1)
                .foregroundStyle(model.state.currentValue == nil ? Palette.dim : Palette.text)
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
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Palette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(model.state.isFrozen ? Palette.freeze.opacity(0.8) : Color.clear, lineWidth: 2)
                )
        )
        .onChange(of: model.peakPulse) { _, _ in
            withAnimation(.spring(duration: 0.18)) { bump = true }
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.spring(duration: 0.25)) { bump = false }
            }
        }
    }
}

struct SlotRowView: View {
    var model: GameViewModel

    private var isInserting: Bool {
        if case .pickInsertPosition = model.interaction { return true }
        return false
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isInserting ? 2 : 6) {
                ForEach(0...model.state.slots.count, id: \.self) { i in
                    gap(at: i)
                    if i < model.state.slots.count {
                        SlotTile(model: model, index: i)
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: 72)
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
                    .frame(width: 26, height: 60)
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 0, height: 60)
        }
    }
}

struct SlotTile: View {
    var model: GameViewModel
    let index: Int

    var body: some View {
        let slot = model.state.slots[index]
        let text = model.state.effectiveText(at: index)
        let digitValue = text.flatMap(Int.init)
        let selected = model.state.selectedSlot == index
        let convertTarget: Bool = {
            if case .pickConvertTarget = model.interaction { return slot.kind != .echo || true }
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
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(text.flatMap(Int.init) == nil ? Palette.text : Palette.digitColor(digitValue))
                .opacity(slot.kind == .echo ? 0.75 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
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
        .frame(width: 48, height: 60)
        .contentShape(Rectangle())
        .onTapGesture { model.tapSlot(index) }
        .onLongPressGesture(minimumDuration: 0.45) { model.longPressSlot(index) }
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

struct InteractionHint: View {
    var model: GameViewModel

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(model.interaction == .normal ? Palette.dim : Palette.accent)
            .frame(maxWidth: .infinity, minHeight: 18)
            .multilineTextAlignment(.center)
            .lineLimit(2)
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
                .buttonStyle(.plain)
                .disabled(model.interaction != .normal)
            }
            if model.state.inventory.isEmpty {
                Text("Bag is empty")
                    .font(.footnote)
                    .foregroundStyle(Palette.dim.opacity(0.7))
            }
            Spacer()
            if case .pickRepairTarget = model.interaction {
                Button(String(localized: "Cancel")) { model.cancelRepairTargeting() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
        }
        .frame(height: 36)
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

struct KeyboardView: View {
    var model: GameViewModel

    private var isRepairTargeting: Bool {
        switch model.interaction {
        case .pickRepairTarget, .pickRepairNowTarget: return true
        default: return false
        }
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(model.state.keys.indices, id: \.self) { index in
                KeyCap(
                    key: model.state.keys[index],
                    highlighted: isRepairTargeting,
                    enabled: isRepairTargeting || (!model.state.keys[index].isDead && !model.interaction.isChoice)
                ) {
                    model.pressKey(index)
                }
            }
        }
    }
}

struct KeyCap: View {
    let key: KeyState
    let highlighted: Bool
    let enabled: Bool
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
                Text(key.symbol.description)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(key.isDead ? Palette.dim.opacity(0.5) : Palette.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("\(max(key.uses, 0))")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(key.uses <= 2 ? Palette.danger : Palette.dim)
                    .padding(6)
            }
            .frame(height: 58)
        }
        .buttonStyle(KeyCapButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

struct KeyCapButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

struct KindPickerOverlay: View {
    let choices: [SlotKind]
    let onPick: (SlotKind) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text("New slot! Choose its type")
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                ForEach(choices, id: \.self) { kind in
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
                    .buttonStyle(.plain)
                }
                Text("Rot is paused while you choose.")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(Palette.panel))
            .padding(24)
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

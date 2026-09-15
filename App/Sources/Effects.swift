import SwiftUI

// MARK: - 漂浮符号背景

/// 背景里缓慢上浮的数字和运算符，给首页和结果页一点"游戏"氛围。减弱动态效果时静止。
struct FloatingSymbolsBackground: View {
    var density: Int = 22
    var opacity: Double = 0.09
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let glyphs = ["9", "7", "3", "^", "!", "×", "8", "5", "(", ")", "2", "6"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            Canvas { canvas, size in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                for i in 0..<density {
                    let seed = Double(i) * 0.6180339887
                    let fract = seed - seed.rounded(.down)
                    let x = fract * size.width
                    let speed = 6 + Double(i % 5) * 2.5
                    let period = size.height + 80
                    let yRaw = period - ((t * speed + Double(i) * 137).truncatingRemainder(dividingBy: period))
                    let sway = sin(t * 0.5 + Double(i)) * 8
                    let scale = 0.7 + Double(i % 4) * 0.25
                    let glyph = Self.glyphs[i % Self.glyphs.count]
                    let text = Text(glyph)
                        .font(.system(size: 26 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(opacity))
                    canvas.draw(text, at: CGPoint(x: x + sway, y: yRaw - 40))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// MARK: - 粒子爆发

/// 触发值变化时从中心炸开一圈粒子，用于跨阈值和结果页。频繁事件不要用它。
struct BurstView: View {
    var trigger: Int
    var color: Color = Palette.accent
    var count: Int = 18
    var radius: CGFloat = 90
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    private let duration: TimeInterval = 0.7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: startedAt == nil)) { context in
            Canvas { canvas, size in
                guard let startedAt else { return }
                let progress = min(context.date.timeIntervalSince(startedAt) / duration, 1)
                guard progress < 1 else { return }
                let eased = 1 - pow(1 - progress, 3)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for i in 0..<count {
                    let angle = (Double(i) / Double(count)) * .pi * 2 + Double(i % 3) * 0.2
                    let distance = radius * eased * (0.7 + Double(i % 4) * 0.12)
                    let x = center.x + CGFloat(cos(angle)) * distance
                    let y = center.y + CGFloat(sin(angle)) * distance + CGFloat(progress * progress) * 24
                    let dot = 3.5 * (1 - progress * 0.6)
                    let rect = CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)
                    canvas.fill(Path(ellipseIn: rect), with: .color(color.opacity(1 - progress)))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            startedAt = Date()
            Task {
                try? await Task.sleep(for: .seconds(duration + 0.05))
                if let startedAt, Date().timeIntervalSince(startedAt) >= duration { self.startedAt = nil }
            }
        }
    }
}

// MARK: - 抖动

/// 水平抖动，`trigger` 每变一次抖一次。用于键报废、数字腐烂。
struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 5
    var shakes: CGFloat = 3
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let offset = amount * sin(animatableData * .pi * shakes * 2)
        return ProjectionTransform(CGAffineTransform(translationX: offset, y: 0))
    }
}

extension View {
    /// 每次 `trigger` 变化播放一次 220 毫秒的抖动；减弱动态效果时不动。
    func shake(on trigger: Int, amount: CGFloat = 5) -> some View {
        modifier(ShakeModifier(trigger: trigger, amount: amount))
    }
}

private struct ShakeModifier: ViewModifier {
    var trigger: Int
    var amount: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(amount: amount, animatableData: phase))
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                phase = 0
                withAnimation(.linear(duration: 0.22)) { phase = 1 }
            }
    }
}

// MARK: - 闪光

/// 全屏一闪，`trigger` 每变一次闪一次。
struct FlashOverlay: View {
    var trigger: Int
    var color: Color = Palette.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        color
            .opacity(visible ? 0.16 : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.06)) { visible = true }
                withAnimation(.easeOut(duration: 0.4).delay(0.06)) { visible = false }
            }
    }
}

// MARK: - 发光

extension View {
    /// 用同色阴影模拟发光，`strength` 0 到 1。
    func glow(_ color: Color, strength: Double) -> some View {
        self
            .shadow(color: color.opacity(0.55 * strength), radius: 6 + 14 * strength)
            .shadow(color: color.opacity(0.25 * strength), radius: 28 * strength)
    }
}

// MARK: - 交错入场

/// 子视图出现时从下方 8 点淡入，按 `index` 交错 45 毫秒。
struct StaggeredAppear: ViewModifier {
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 8)
            .onAppear {
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.easeOut(duration: 0.28).delay(Double(index) * 0.045)) { shown = true }
                }
            }
    }
}

extension View {
    func staggeredAppear(index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}

/// 游戏里通用的弹簧：默认临界阻尼；`bouncy` 只给庆祝和有动量的场合。
enum Motion {
    static let snappy = Animation.spring(duration: 0.28, bounce: 0)
    static let settle = Animation.spring(duration: 0.4, bounce: 0.1)
    static let bouncy = Animation.spring(duration: 0.45, bounce: 0.3)
}

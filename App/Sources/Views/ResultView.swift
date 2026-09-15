import SwiftUI
import PlsInputCore

struct ResultView: View {
    var model: GameViewModel
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var burst = 0

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            FloatingSymbolsBackground(density: 16, opacity: 0.07)
            VStack(spacing: 22) {
                Spacer()
                Text(model.mode == .daily ? "Today's result" : "Practice result")
                    .font(.headline)
                    .foregroundStyle(Palette.dim)
                    .staggeredAppear(index: 0)
                ZStack {
                    BurstView(trigger: burst, color: Palette.accent, count: 28, radius: 150)
                    Text(model.peakText)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                        .foregroundStyle(Palette.accent)
                        .glow(Palette.accent, strength: 0.8)
                        .padding(.horizontal, 24)
                        .scaleEffect(revealed ? 1 : 0.9)
                        .opacity(revealed ? 1 : 0)
                }

                VStack(spacing: 8) {
                    row(String(localized: "Rewards claimed"), "\(model.state.crossedTiers) / \(model.state.puzzle.thresholds.count)")
                        .staggeredAppear(index: 3)
                    row(String(localized: "Time"), model.clockText)
                        .staggeredAppear(index: 4)
                    row(String(localized: "Ended by"), endReasonText)
                        .staggeredAppear(index: 5)
                    if model.mode == .daily {
                        row(String(localized: "Rank"), rankText)
                            .staggeredAppear(index: 6)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.panel))
                .padding(.horizontal, 24)
                .staggeredAppear(index: 2)

                Spacer()

                ShareLink(item: shareText) {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.tileRaised))
                        .foregroundStyle(Palette.text)
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.horizontal, 24)
                .staggeredAppear(index: 7)

                Button {
                    app.dismissGame()
                } label: {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.accent))
                        .foregroundStyle(Palette.background)
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .staggeredAppear(index: 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(Motion.bouncy.delay(0.12)) { revealed = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    burst += 1
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Palette.dim)
            Spacer()
            Text(value).foregroundStyle(Palette.text).monospacedDigit()
        }
        .font(.subheadline)
    }

    private var endReasonText: String {
        guard case .ended(let reason) = model.state.phase else { return "" }
        switch reason {
        case .keysExhausted: return String(localized: "Keys worn out")
        case .playerEnded: return String(localized: "You ended it")
        case .timeCap: return String(localized: "Time limit")
        }
    }

    private var rankText: String {
        if let rank = app.today?.rank { return "#\(rank)" }
        if app.today?.submitted == true { return String(localized: "Submitted") }
        if !app.gameCenter.isAuthenticated { return String(localized: "Sign in to Game Center to rank") }
        return String(localized: "Submitting…")
    }

    private var shareText: String {
        let day = app.today?.day ?? app.currentDay
        if model.mode == .daily {
            if let rank = app.today?.rank {
                return String(localized: "PlsInput \(day) · \(model.peakText) · #\(rank)")
            }
            return String(localized: "PlsInput \(day) · \(model.peakText)")
        }
        return String(localized: "PlsInput practice · \(model.peakText)")
    }
}

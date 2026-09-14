import SwiftUI
import PlsInputCore

struct ResultView: View {
    var model: GameViewModel
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                Text(model.mode == .daily ? "Today's result" : "Practice result")
                    .font(.headline)
                    .foregroundStyle(Palette.dim)
                Text(model.peakText)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 24)

                VStack(spacing: 8) {
                    row(String(localized: "Rewards claimed"), "\(model.state.crossedTiers) / \(model.state.puzzle.thresholds.count)")
                    row(String(localized: "Time"), model.clockText)
                    row(String(localized: "Ended by"), endReasonText)
                    if model.mode == .daily {
                        row(String(localized: "Rank"), rankText)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.panel))
                .padding(.horizontal, 24)

                Spacer()

                ShareLink(item: shareText) {
                    Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.tileRaised))
                        .foregroundStyle(Palette.text)
                }
                .padding(.horizontal, 24)

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
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
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

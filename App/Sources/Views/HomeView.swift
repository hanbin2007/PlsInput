import SwiftUI
import PlsInputCore

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        header
                        if let notice = app.notice {
                            banner(notice, color: Palette.stable)
                        }
                        if app.requiresUpdate {
                            banner(String(localized: "This version is too old for today's puzzle. Please update the app."), color: Palette.danger)
                        }
                        todayCard
                        practiceCard
                        NavigationLink {
                            LeaderboardView()
                        } label: {
                            rowLink(String(localized: "Leaderboard"), systemImage: "list.number")
                        }
                        NavigationLink {
                            SettingsView()
                        } label: {
                            rowLink(String(localized: "Settings"), systemImage: "gearshape")
                        }
                    }
                    .padding(20)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: Binding(
            get: { app.activeGame != nil },
            set: { if !$0 { app.dismissGame() } }
        )) {
            if let game = app.activeGame {
                GameContainerView(model: game)
                    .environment(app)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.rollDayIfNeeded() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PlsInput")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text)
            Text("Type the biggest number you can.")
                .font(.subheadline)
                .foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Daily puzzle")
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                Spacer()
                Text(app.currentDay)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Palette.dim)
            }
            if let record = app.today, let result = record.result {
                Text(BigNumFormatter.string(result.peak))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .foregroundStyle(Palette.accent)
                HStack {
                    Text(String(localized: "Rewards claimed: \(result.tiersCrossed)"))
                    Spacer()
                    if let rank = record.rank {
                        Text("#\(rank)")
                    } else if !app.gameCenter.isAuthenticated {
                        Text("Not ranked")
                    }
                }
                .font(.footnote)
                .foregroundStyle(Palette.dim)
                Text("Come back tomorrow for a new puzzle.")
                    .font(.footnote)
                    .foregroundStyle(Palette.dim)
            } else if app.today?.isInProgress == true {
                primaryButton(String(localized: "Continue")) { app.startDaily() }
            } else {
                Text("One attempt per day. Everyone gets the same keyboard.")
                    .font(.footnote)
                    .foregroundStyle(Palette.dim)
                primaryButton(String(localized: "Play today's puzzle")) { app.startDaily() }
                    .disabled(app.requiresUpdate)
                    .opacity(app.requiresUpdate ? 0.5 : 1)
            }
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(app.streak > 0 ? Palette.amp : Palette.dim)
                Text(String(localized: "\(app.streak) day streak"))
                    .foregroundStyle(Palette.dim)
            }
            .font(.footnote)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.panel))
    }

    private var practiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Practice")
                .font(.headline)
                .foregroundStyle(Palette.text)
            Text("Random puzzles, unlimited tries, no ranking.")
                .font(.footnote)
                .foregroundStyle(Palette.dim)
            if let best = app.stats.practiceBest {
                Text(String(localized: "Best: \(BigNumFormatter.string(best))"))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Palette.accent)
            }
            Button {
                app.startPractice()
            } label: {
                Text("Practice")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.tileRaised))
                    .foregroundStyle(Palette.text)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.panel))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accent))
                .foregroundStyle(Palette.background)
        }
    }

    private func rowLink(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .foregroundStyle(Palette.text)
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(Palette.dim)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.panel))
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.25)))
    }
}

import SwiftUI
import PlsInputCore

/// 自绘排行榜：每日榜与总榜，可只看好友。任务 6 会接上真实数据。
struct LeaderboardView: View {
    @Environment(AppModel.self) private var app

    enum Board: String, CaseIterable, Identifiable {
        case daily
        case allTime
        var id: String { rawValue }
        var leaderboardID: String {
            switch self {
            case .daily: return LeaderboardID.daily
            case .allTime: return LeaderboardID.allTime
            }
        }
        var title: String {
            switch self {
            case .daily: return String(localized: "Today")
            case .allTime: return String(localized: "All time")
            }
        }
    }

    @State private var board: Board = .daily
    @State private var friendsOnly = false
    @State private var page: GameCenterService.Page?
    @State private var errorText: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 12) {
            Picker("Board", selection: $board) {
                ForEach(Board.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(String(localized: "Friends only"), isOn: $friendsOnly)
                .font(.subheadline)
            content
        }
        .padding(16)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(String(localized: "Leaderboard"))
        .task(id: "\(board.rawValue)-\(friendsOnly)-\(app.gameCenter.isAuthenticated)") { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if !app.gameCenter.isAuthenticated {
            placeholder(String(localized: "Sign in to Game Center to see rankings."), action: (String(localized: "Sign in"), { app.gameCenter.authenticate() }))
        } else if isLoading && page == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            placeholder(errorText, action: (String(localized: "Retry"), { Task { await load() } }))
        } else if let page {
            if page.entries.isEmpty {
                placeholder(String(localized: "No scores yet."), action: nil)
            } else {
                List {
                    ForEach(page.entries) { entry in
                        row(entry)
                    }
                    if let local = page.localEntry, !page.entries.contains(where: { $0.isLocalPlayer }) {
                        Section(String(localized: "You")) { row(local) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        } else {
            Spacer()
        }
    }

    private func row(_ entry: GameCenterService.Entry) -> some View {
        HStack(spacing: 12) {
            Text("#\(entry.rank)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Palette.dim)
                .frame(width: 48, alignment: .leading)
            Text(entry.displayName)
                .font(.subheadline.weight(entry.isLocalPlayer ? .bold : .regular))
                .foregroundStyle(entry.isLocalPlayer ? Palette.accent : Palette.text)
                .lineLimit(1)
            Spacer()
            Text(BigNumFormatter.string(ScoreCodec.decode(.init(score: entry.score, context: entry.context))))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .listRowBackground(Palette.panel)
    }

    private func placeholder(_ text: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Palette.dim)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.0, action: action.1)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        guard app.gameCenter.isAuthenticated else { return }
        isLoading = true
        errorText = nil
        do {
            page = try await app.gameCenter.loadEntries(
                leaderboardID: board.leaderboardID,
                scope: friendsOnly ? .friends : .global,
                range: 0..<100
            )
        } catch {
            errorText = String(localized: "Couldn't load the leaderboard.")
        }
        isLoading = false
    }
}

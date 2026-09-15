import SwiftUI

@main
struct PlsInputApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(app)
                .task {
                    await app.bootstrap()
                    LaunchArguments.apply(to: app)
                }
        }
    }
}

/// 开发用启动参数：`--autostart-practice [--seed <seed>]`、`--autostart-daily`。
enum LaunchArguments {
    @MainActor
    static func apply(to app: AppModel) {
        let args = CommandLine.arguments
        if args.contains("--autostart-practice") {
            var seed: String?
            if let i = args.firstIndex(of: "--seed"), i + 1 < args.count {
                seed = args[i + 1]
            }
            app.startPractice(seed: seed)
        } else if args.contains("--autostart-daily") {
            app.startDaily()
        } else if args.contains("--autostart-tutorial") {
            app.startTutorial()
        }
        if args.contains("--skip-tutorial") {
            app.settings.tutorialCompleted = true
        }
        if let i = args.firstIndex(of: "--script"), i + 1 < args.count, let game = app.activeGame {
            tutorialApp = app
            Task { await play(script: args[i + 1], on: game) }
        }
    }

    /// 逗号分隔的动作：k<键> s<格> g<缝隙> c<候选序号> v<格> r<键> i<道具> w<秒> l<格>(长按清空) e(结束)。
    @MainActor private static weak var tutorialApp: AppModel?

    @MainActor
    static func play(script: String, on game: GameViewModel) async {
        for raw in script.split(separator: ",") {
            let step = raw.trimmingCharacters(in: .whitespaces)
            guard let op = step.first else { continue }
            let arg = String(step.dropFirst())
            let n = Int(arg) ?? 0
            switch op {
            case "k": game.pressKey(n)
            case "s": game.tapSlot(n)
            case "l": game.longPressSlot(n)
            case "g": game.tapGap(n)
            case "v": game.tapSlot(n)
            case "r": game.pressKey(n)
            case "i": game.tapItem(n)
            case "c":
                if case .pickKind(let choices) = game.interaction, choices.indices.contains(n) {
                    game.chooseKind(choices[n])
                }
            case "w":
                try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
            case "e": game.end()
            case "n":
                if let app = tutorialApp { app.activeTutorial?.advanceIfManual() }
            default: break
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }
}

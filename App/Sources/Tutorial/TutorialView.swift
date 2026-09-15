import SwiftUI
import PlsInputCore

/// 教程页：普通对局页加上引导气泡、焦点压暗和跳过按钮。
struct TutorialView: View {
    var game: GameViewModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let controller = app.activeTutorial
        ZStack(alignment: .topLeading) {
            GameView(
                model: game,
                focus: controller?.current?.focus,
                coach: controller?.coach,
                onCoachContinue: {
                    guard let controller else { return }
                    if controller.isLastStep {
                        app.completeTutorial()
                    } else {
                        controller.advanceIfManual()
                    }
                },
                hideEnd: true
            )
            Button {
                app.completeTutorial()
            } label: {
                Text("Skip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.dim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Palette.panel))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.leading, 16)
            .padding(.top, 8)
        }
        .onChange(of: game.state) { _, _ in controller?.check() }
        .onChange(of: game.interaction) { _, _ in controller?.check() }
    }
}

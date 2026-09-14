import SwiftUI

@main
struct PlsInputApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(app)
                .task { await app.bootstrap() }
        }
    }
}

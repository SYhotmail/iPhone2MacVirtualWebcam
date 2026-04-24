import SwiftUI

struct QuickSetupCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Quick Setup") {
                openWindow(id: "quick-setup")
            }
            .keyboardShortcut("H", modifiers: [.command, .shift])
        }
    }
}

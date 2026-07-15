import SwiftUI

@main
struct CCVerifyApp: App {
    @StateObject private var store: AppStore
    @StateObject private var poller: Poller

    init() {
        AppSettings.registerDefaults()
        let store = AppStore()
        let poller = Poller(store: store)
        _store = StateObject(wrappedValue: store)
        _poller = StateObject(wrappedValue: poller)
        // Started here, not from a view .task: MenuBarExtra labels render via
        // NSStatusItem and never fire view lifecycle modifiers.
        poller.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(store)
                .environmentObject(poller)
        } label: {
            Image(systemName: "checkmark.seal")
        }
        .menuBarExtraStyle(.window)

        Window("CCVerify History", id: "history") {
            HistoryView()
                .environmentObject(store)
                .environmentObject(poller)
        }
        .defaultSize(width: 950, height: 600)

        Settings {
            SettingsView()
        }
    }
}

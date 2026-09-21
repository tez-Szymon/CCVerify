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
        // Delegate has to be in place before the app finishes launching, or
        // a click on an already-posted banner is dropped.
        Notifier.shared.start()
        Notifier.onOpenRun = { [store] runID in
            store.reveal(runID)
            WindowRouter.showHistory()
        }
    }

    var body: some Scene {
        // First scene = the app's main window: shown at launch, re-presented
        // when the Dock icon is clicked, listed in the Window menu.
        Window("CCVerify", id: "history") {
            MainWindow()
                .environmentObject(store)
                .environmentObject(poller)
        }
        .defaultSize(width: 950, height: 600)
        .commands {
            AppCommands(store: store, poller: poller)
        }

        MenuBarExtra {
            MenuContent()
                .environmentObject(store)
                .environmentObject(poller)
        } label: {
            Image(systemName: "checkmark.seal")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The main window hosts both the run history and, in place of it, the
/// settings screen — settings are an in-window view, not a separate modal.
struct MainWindow: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if store.showingSettings {
                SettingsScreen()
            } else {
                HistoryView()
            }
        }
        // Hand `openWindow` to code that lives outside any scene — a clicked
        // notification has to reopen this window even after it was closed.
        .onAppear { WindowRouter.openHistory = { openWindow(id: "history") } }
    }
}

/// Menu-bar (top of screen) commands for the main window. The Settings scene
/// contributes "Settings…" (⌘,) to the app menu by itself.
struct AppCommands: Commands {
    @ObservedObject var store: AppStore
    @ObservedObject var poller: Poller
    @Environment(\.openWindow) private var openWindow
    // @AppStorage so the menu picks up repos checked in Settings immediately.
    @AppStorage(AppSettings.Keys.depUpdateRepos) private var depUpdateReposRaw = ""
    @AppStorage(AppSettings.Keys.ticketAnalysisRepos) private var ticketAnalysisReposRaw = ""

    var body: some Commands {
        // Settings live inside the main window now — point ⌘, there instead
        // of the stock Settings scene.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "history")
                NSApp.activate(ignoringOtherApps: true)
                store.showingSettings = true
            }
            .keyboardShortcut(",")
        }

        // A watcher app has nothing to "New" — drop the stock File > New item.
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Runs") {
            Button("Poll Now") {
                Task { await poller.tick(force: true) }
            }
            .keyboardShortcut("r")
            .disabled(poller.isPolling)

            Button(store.isPaused ? "Resume Watching" : "Pause Watching") {
                store.isPaused.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            // Stops the agents, not the watching: polling carries on, so a
            // stopped run can be started again from History.
            Button("Stop All Runs") {
                poller.stopAll()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!poller.hasStoppableRuns)

            Divider()

            let repos = AppSettings.repoList(depUpdateReposRaw)
            if repos.isEmpty {
                Button("Scan for Updates (add repos in Settings)") {}
                    .disabled(true)
            } else {
                Menu("Scan for Updates") {
                    ForEach(repos, id: \.self) { repo in
                        Button(repo) { poller.scanDependencies(repo) }
                            .disabled(poller.isActive(.dependencyUpdate, repo: repo))
                    }
                }
            }

            let ticketRepos = AppSettings.repoList(ticketAnalysisReposRaw)
            if ticketRepos.isEmpty {
                Button("Analyze Major Tickets (add repos in Settings)") {}
                    .disabled(true)
            } else {
                Menu("Analyze Major Tickets") {
                    ForEach(ticketRepos, id: \.self) { repo in
                        Button(repo) { poller.analyzeTickets(repo) }
                            .disabled(poller.isActive(.ticketAnalysis, repo: repo))
                    }
                }
            }
        }
    }
}

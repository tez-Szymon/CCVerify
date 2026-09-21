import AppKit
import UserNotifications

/// Notifications posted by the app itself through UserNotifications.
///
/// They used to be posted with `osascript -e 'display notification …'`, which
/// makes them Script Editor's notifications: Script Editor's icon, and Script
/// Editor launched when one was clicked. Posting them here means they carry
/// CCVerify's icon and a run id, so a click can open the app on that run.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Run a clicked notification points at. Set by the app at launch.
    @MainActor static var onOpenRun: ((UUID) -> Void)?

    private static let runIDKey = "runID"
    /// UNUserNotificationCenter needs a bundle — nil when run via `swift run`
    /// rather than from CCVerify.app, where touching it would trap.
    private let isBundled = Bundle.main.bundleIdentifier != nil

    func start() {
        guard isBundled else {
            AppLog.log("Notifications off: running unbundled (build with build.sh to get them)")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.log("Notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                AppLog.log("Notifications denied — enable CCVerify under System Settings → Notifications")
            }
        }
    }

    func post(title: String, body: String, runID: UUID?) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let runID { content.userInfo = [Self.runIDKey: runID.uuidString] }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { AppLog.log("Notification failed: \(error.localizedDescription)") }
        }
    }

    /// True when macOS itself is blocking our notifications — the toggle in
    /// Settings then has no effect, so the UI says where to fix it.
    func blockedBySystem() async -> Bool {
        guard isBundled else { return false }
        return await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus == .denied
    }

    static func openSystemNotificationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Banners are the whole point of a watcher app, so show them even while
    /// CCVerify is the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo[Self.runIDKey] as? String
        let runID = raw.flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if let runID {
                Self.onOpenRun?(runID)
            } else {
                WindowRouter.showHistory()
            }
            completionHandler()
        }
    }
}

/// Reopening the history window from outside SwiftUI (a notification click).
/// `openWindow` only exists inside a scene's environment, so the main window
/// hands its copy over the first time it appears — at launch, before any
/// notification can be clicked.
@MainActor
enum WindowRouter {
    static var openHistory: (() -> Void)?

    static func showHistory() {
        if let openHistory {
            openHistory()
        } else {
            // No scene has appeared yet: settle for whatever window exists.
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

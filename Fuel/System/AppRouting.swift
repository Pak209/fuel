import Foundation
import UIKit
import UserNotifications

enum AppRoute: String, Identifiable, Hashable, Sendable {
    case today
    case scan
    case insights
    case meals
    case notificationSettings
    case healthConnection
    case addWater

    var id: String { rawValue }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "fuel" else { return nil }
        let destination = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
            .map { $0.lowercased() }
            .joined(separator: "/")
        switch destination {
        case "today": self = .today
        case "today/water": self = .addWater
        case "scan": self = .scan
        case "insights": self = .insights
        case "meals": self = .meals
        case "profile/notifications": self = .notificationSettings
        case "profile/health": self = .healthConnection
        default: return nil
        }
    }
}

extension Notification.Name {
    static let fuelRouteRequested = Notification.Name("com.pak.fuel.routeRequested")
}

final class NotificationRouteCoordinator: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated static let deepLinkKey = "fuelDeepLink"
    nonisolated static let quickAddWaterAction = "fuel.action.addWater"
    nonisolated static let openAction = "fuel.action.open"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(center: center)
        application.shortcutItems = [
            UIApplicationShortcutItem(
                type: "com.pak.fuel.scan",
                localizedTitle: "Scan a meal",
                localizedSubtitle: "Open the meal camera",
                icon: UIApplicationShortcutIcon(systemImageName: "camera.viewfinder")
            )
        ]
        return true
    }

    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard shortcutItem.type == "com.pak.fuel.scan" else {
            completionHandler(false)
            return
        }
        post(URL(string: "fuel://scan")!)
        completionHandler(true)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.actionIdentifier == Self.quickAddWaterAction {
            post(URL(string: "fuel://today/water?add=250")!)
            return
        }
        if let value = response.notification.request.content.userInfo[Self.deepLinkKey] as? String,
           let url = URL(string: value) {
            post(url)
        }
    }

    nonisolated static func categoryIdentifier(for kind: ReminderKind) -> String {
        switch kind {
        case .hydration: "fuel.category.hydration"
        default: "fuel.category.open"
        }
    }

    private func registerCategories(center: UNUserNotificationCenter) {
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open Fuel", options: [.foreground])
        let addWater = UNNotificationAction(identifier: Self.quickAddWaterAction, title: "Add 250 ml", options: [.foreground])
        let hydration = UNNotificationCategory(
            identifier: "fuel.category.hydration",
            actions: [addWater, open],
            intentIdentifiers: [],
            options: []
        )
        let defaultCategory = UNNotificationCategory(
            identifier: "fuel.category.open",
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([hydration, defaultCategory])
    }

    private func post(_ url: URL) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .fuelRouteRequested, object: url)
        }
    }
}

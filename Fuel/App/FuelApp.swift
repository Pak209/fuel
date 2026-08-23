import SwiftUI
import SwiftData
import CoreData
import CoreSpotlight

@main
struct FuelApp: App {
    @UIApplicationDelegateAdaptor(NotificationRouteCoordinator.self) private var notificationRouteCoordinator
    @State private var appState = AppState()
    @State private var hasEndedColdLaunchSignpost = false
    private let container: ModelContainer
    private let startupError: String?
    /// Begun in `init()` (true process cold launch) and ended once the first
    /// scene body has appeared — see `hasEndedColdLaunchSignpost` below. Kept
    /// out of `body`/view code so it never re-fires on state-driven re-renders.
    private let coldLaunchSignpost = FuelSignpost.begin(.coldLaunch)

    init() {
        // Best-effort, one-time startup side effects. Neither of these touches
        // any view — they run once per process launch, before `body` is ever
        // evaluated, and must never run again on a state-driven re-render.
        if FeatureFlagStore.shared.resolvedValue(for: .metricKitCollectionEnabled) {
            MetricsCollector.shared.start()
        }
        let schema = Schema(versionedSchema: FuelSchemaV3.self)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-FuelDemoData") {
            do {
                let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                container = try ModelContainer(for: schema, configurations: [configuration])
                startupError = nil
                return
            } catch {
                fatalError("Unable to initialize Fuel's demo data store: \(error.localizedDescription)")
            }
        }
        #endif
        do {
            // Two guards, both routed through `ObjCExceptionCatcher`, because a
            // damaged store makes Core Data *raise* rather than throw and Swift
            // `catch` never sees it (the app then crash-loops instead of
            // reaching `StartupFailureView`). First read the existing store's
            // metadata; then build the container — the crash was observed
            // inside container construction, so both need the net.
            if let reason = StoreHealth.openFailureReason(forStoreAt: StoreHealth.defaultStoreURL(for: schema)) {
                throw StoreHealth.OpenFailure(message: reason)
            }
            container = try StoreHealth.catchingObjCExceptions {
                try ModelContainer(for: schema, migrationPlan: FuelMigrationPlan.self)
            }
            startupError = nil
        } catch {
            startupError = error.localizedDescription
            do {
                let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                container = try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Unable to initialize Fuel's recovery data store: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let startupError { StartupFailureView(message: startupError) }
                else { AppRootView(state: appState) }
            }
                .preferredColorScheme(appState.preferences.appearance.colorScheme)
                .tint(FuelTheme.green)
                // Ends the cold-launch signpost once the first scene body has
                // appeared. `.task` runs once per stable view identity, not on
                // every re-render, so this is a one-shot lifecycle hook rather
                // than render-path work; the boolean guard is cheap insurance
                // against ever closing the same signpost interval twice.
                .task {
                    guard !hasEndedColdLaunchSignpost else { return }
                    hasEndedColdLaunchSignpost = true
                    FuelSignpost.end(coldLaunchSignpost)
                }
                // Spotlight deep link: tapping a search result for an indexed
                // meal (see `SpotlightIndexer`) hands the app a userActivity of
                // this well-known type. Route it through the same URL-based
                // handling used everywhere else rather than a bespoke path.
                .onContinueUserActivity(CSSearchableItemActionType) { _ in
                    guard let url = URL(string: "fuel://meals") else { return }
                    Task { await appState.handle(url) }
                }
        }
            .modelContainer(container)
    }
}

/// Startup checks for the on-disk SwiftData store.
///
/// SwiftData opens its store through `NSPersistentStoreCoordinator`, which
/// reports some unrecoverable conditions (a truncated or non-SQLite file, an
/// unreadable store) by raising an `NSException`. Swift cannot catch those, so
/// the process aborts before the `do`/`catch` in `FuelApp.init` can fall back
/// to an in-memory container. Everything here funnels the dangerous calls
/// through `ObjCExceptionCatcher` so both failure shapes — raised exception and
/// thrown `NSError` — arrive as ordinary Swift errors.
///
/// Nothing here deletes or moves the user's store: a failure surfaces in
/// `StartupFailureView`, which is where recovery choices belong.
enum StoreHealth {
    /// Where SwiftData will actually put the default on-disk store.
    ///
    /// Asking `ModelConfiguration` rather than hardcoding
    /// `URL.applicationSupportDirectory/default.store`: because Fuel ships an
    /// app group (shared with the widgets), SwiftData resolves the default
    /// store into the *group* container, so the app-support guess points at a
    /// file that never exists and the check would silently never fire.
    static func defaultStoreURL(for schema: Schema) -> URL {
        ModelConfiguration(schema: schema).url
    }

    /// A failure carrying an already user-readable message.
    struct OpenFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs `body`, converting a raised `NSException` into a thrown Swift error.
    static func catchingObjCExceptions<T>(_ body: () throws -> T) throws -> T {
        var outcome: Result<T, Error>?
        try ObjCExceptionCatcher.catchException {
            outcome = Result { try body() }
        }
        guard let outcome else {
            throw OpenFailure(message: "The data store could not be opened.")
        }
        return try outcome.get()
    }

    /// Reads the store's metadata to find out whether it can be opened at all.
    ///
    /// - Returns: `nil` when there is no store yet or the store reads cleanly;
    ///   otherwise a user-readable description of the failure.
    static func openFailureReason(forStoreAt url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            try catchingObjCExceptions {
                _ = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct StartupFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Fuel couldn’t open your data", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Your existing data has not been deleted. Close and reopen Fuel. If this continues, keep the app installed and seek support before clearing data.\n\n\(message)")
        }
        .padding()
    }
}

struct AppRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var state: AppState

    var body: some View {
        rootContent
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(FuelTheme.panel, for: .tabBar)
        .task {
            state.configure(context: modelContext)
            await state.loadInitialData()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, state.isConfigured else { return }
            Task {
                await state.refresh()
                await state.consumeSharedRoute()
            }
        }
        .onOpenURL { url in
            Task { await state.handle(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fuelRouteRequested)) { note in
            guard let url = note.object as? URL else { return }
            Task { await state.handle(url) }
        }
        .sheet(item: $state.presentedRoute) { route in
            NavigationStack {
                switch route {
                case .notificationSettings:
                    NotificationPreferencesView(state: state)
                case .healthConnection:
                    HealthPermissionView(state: state)
                case .addWater:
                    HydrationLogView(state: state)
                default:
                    ContentUnavailableView("Destination unavailable", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let message = state.transientMessage {
                TransientMessageBanner(message: message)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 74)
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(3))
                        if state.transientMessage == message { state.transientMessage = nil }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        #if DEBUG
        if debugScreen == "MealEditor" {
            NavigationStack { MealEditorView(state: state) }
        } else {
            productionContent
        }
        #else
        productionContent
        #endif
    }

    @ViewBuilder
    private var productionContent: some View {
        Group {
            if showsOnboarding {
                OnboardingView(state: state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabView(selection: $state.selectedTab) {
                    TodayView(state: state)
                        .tabItem { Label("Today", systemImage: AppTab.today.icon) }
                        .tag(AppTab.today)
                    NavigationStack { ScanView(state: state) }.tabItem { Label("Scan", systemImage: AppTab.scan.icon) }.tag(AppTab.scan)
                    NavigationStack { InsightsView(state: state) }.tabItem { Label("Insights", systemImage: AppTab.insights.icon) }.tag(AppTab.insights)
                    NavigationStack { MealsView(state: state) }.tabItem { Label("Meals", systemImage: AppTab.meals.icon) }.tag(AppTab.meals)
                    NavigationStack { ProfileView(state: state) }.tabItem { Label("Profile", systemImage: AppTab.profile.icon) }.tag(AppTab.profile)
                }
            }
        }
    }

    private var debugScreen: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-FuelScreen"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private var showsOnboarding: Bool {
        state.dataPhase == .loaded
            && !state.preferences.onboardingCompleted
            && !ProcessInfo.processInfo.arguments.contains("-FuelSkipOnboarding")
    }
}

private struct TransientMessageBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(FuelTheme.border))
            .shadow(radius: 8, y: 3)
            .accessibilityElement(children: .combine)
    }
}

private extension AppAppearance {
    /// v1 ships a single hardcoded dark palette (`FuelTheme`), so every stored
    /// appearance resolves to Dark. Honoring `.light`/`.system` rendered the
    /// app black-on-black on a light-mode device; the appearance picker is
    /// removed from Settings and the stored value is kept only for decoding.
    var colorScheme: ColorScheme { .dark }
}

enum FuelTheme {
    static let background = Color(red: 0.015, green: 0.025, blue: 0.023)
    static let panel = Color(red: 0.07, green: 0.09, blue: 0.085)
    static let panelRaised = Color(red: 0.10, green: 0.12, blue: 0.11)
    static let border = Color.white.opacity(0.14)
    static let secondary = Color(red: 0.66, green: 0.68, blue: 0.71)
    static let green = Color(red: 0.30, green: 0.82, blue: 0.31)
    static let blue = Color(red: 0.18, green: 0.67, blue: 0.95)
    static let orange = Color(red: 1.0, green: 0.68, blue: 0.08)
    static let red = Color(red: 1.0, green: 0.31, blue: 0.22)
    static let teal = Color(red: 0.25, green: 0.72, blue: 0.66)
    static let purple = Color(red: 0.66, green: 0.34, blue: 0.96)
}

extension View {
    func cardStyle(padding: CGFloat = 18) -> some View {
        self.padding(padding)
            .background(FuelTheme.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(FuelTheme.border, lineWidth: 1))
    }
}

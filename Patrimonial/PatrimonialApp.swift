import SwiftUI
import SwiftData

@main
struct PatrimonialApp: App {
    let modelContainer: ModelContainer
    @State private var deepLink: DeepLink?

    init() {
        do {
            modelContainer = try PersistenceController.makeContainer()
        } catch {
            fatalError("Failed to initialize SwiftData: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            PBRootView()
                .onOpenURL { url in
                    deepLink = DeepLink(from: url)
                }
                .environment(\.deepLink, deepLink)
                .onChange(of: deepLink) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        deepLink = nil
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}

enum DeepLink: Equatable {
    case expense
    case income
    case cashflow

    init?(from url: URL) {
        guard url.scheme == "patrimonial" else { return nil }
        switch url.host {
        case "expense": self = .expense
        case "income": self = .income
        case "cashflow": self = .cashflow
        default: return nil
        }
    }
}

private struct DeepLinkKey: EnvironmentKey {
    static let defaultValue: DeepLink? = nil
}

extension EnvironmentValues {
    var deepLink: DeepLink? {
        get { self[DeepLinkKey.self] }
        set { self[DeepLinkKey.self] = newValue }
    }
}

import Foundation

enum AppDefaultsDomain: Equatable {
    case standard
    case suite(String)
}

/// Owns the shared defaults domain used by the packaged app and bare Swift CLI.
enum AppPreferences {
    static let suiteName = "com.stevetrefethen.kickoff"

    static func defaultDomain(bundleIdentifier: String?) -> AppDefaultsDomain {
        bundleIdentifier == suiteName ? .standard : .suite(suiteName)
    }

    static func applicationDefaults(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> UserDefaults {
        switch defaultDomain(bundleIdentifier: bundleIdentifier) {
        case .standard:
            return .standard
        case let .suite(name):
            guard let defaults = UserDefaults(suiteName: name) else {
                preconditionFailure("Could not open the Kickoff preferences suite.")
            }
            return defaults
        }
    }
}

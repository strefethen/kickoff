import Foundation
import Darwin

enum WebsiteValidationError: Error, Equatable, CustomStringConvertible {
    case empty
    case unsupportedScheme
    case invalid

    var description: String {
        switch self {
        case .empty:
            return "Enter a website URL."
        case .unsupportedScheme:
            return "Use an http or https website URL."
        case .invalid:
            return "Enter a valid website URL with a host."
        }
    }
}

/// A normalized website selected for one setup run.
struct WebsiteURL: Equatable {
    static let approvedDefault = try! WebsiteURL("https://www.hulu.com/")

    let url: URL
    let absoluteString: String
    private let scheme: String
    private let host: String
    private let explicitPort: Int?

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebsiteValidationError.empty }
        guard !trimmed.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              Self.hasValidPercentEscapes(trimmed) else {
            throw WebsiteValidationError.invalid
        }

        let candidate: String
        if let scheme = Self.explicitScheme(in: trimmed) {
            guard scheme == "http" || scheme == "https" else {
                throw WebsiteValidationError.unsupportedScheme
            }
            candidate = trimmed
        } else {
            guard !trimmed.hasPrefix("//") else { throw WebsiteValidationError.invalid }
            candidate = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate),
              let parsedScheme = components.scheme?.lowercased(),
              parsedScheme == "http" || parsedScheme == "https",
              components.user == nil,
              components.password == nil,
              let rawHost = components.host,
              !rawHost.isEmpty,
              Self.isValidAuthority(candidate),
              Self.isValidHost(rawHost),
              let originalURL = components.url else {
            throw WebsiteValidationError.invalid
        }

        components.scheme = parsedScheme
        components.host = rawHost.lowercased()
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        guard let normalizedURL = components.url,
              let normalizedHost = normalizedURL.host?.lowercased(),
              !normalizedHost.isEmpty else {
            throw WebsiteValidationError.invalid
        }

        // Reading the original URL ensures Foundation agrees the entire value is
        // an absolute URL before normalized scheme/host casing is applied.
        _ = originalURL
        url = normalizedURL
        absoluteString = normalizedURL.absoluteString
        scheme = parsedScheme
        host = normalizedHost
        explicitPort = components.port
    }

    func matchesPendingAddress(_ value: String) -> Bool {
        value == absoluteString
    }

    func acceptsLoadedURL(_ value: String) -> Bool {
        guard let loaded = try? WebsiteURL(value),
              Self.hostVariants(for: host).contains(loaded.host),
              loaded.scheme == scheme || (scheme == "http" && loaded.scheme == "https") else {
            return false
        }
        let configuredPort = explicitPort ?? Self.defaultPort(for: scheme)
        let loadedPort = loaded.explicitPort ?? Self.defaultPort(for: loaded.scheme)
        if loaded.scheme == scheme {
            return loadedPort == configuredPort
        }
        return configuredPort == Self.defaultPort(for: "http")
            ? loadedPort == Self.defaultPort(for: "https")
            : loadedPort == configuredPort
    }

    func redirectFailure(for values: [String]) -> String? {
        let rejected = values.filter { !acceptsLoadedURL($0) }
        guard !rejected.isEmpty else { return nil }
        return "The configured website redirected to a different host or unsupported scheme/port: \(rejected.joined(separator: ", "))."
    }

    private static func explicitScheme(in value: String) -> String? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let candidate = String(value[..<colon])
        let portCandidate = value[value.index(after: colon)...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        if (candidate.contains(".") || candidate.lowercased() == "localhost"),
           !portCandidate.isEmpty, portCandidate.allSatisfy(\.isNumber), Int(portCandidate) != nil {
            return nil
        }
        guard let first = candidate.unicodeScalars.first,
              CharacterSet.letters.contains(first),
              candidate.unicodeScalars.dropFirst().allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "+" || $0 == "-" || $0 == "."
              }) else {
            return nil
        }
        return candidate.lowercased()
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "%" else { index += 1; continue }
            guard index + 2 < scalars.count,
                  scalars[index + 1].isASCIIHexDigit,
                  scalars[index + 2].isASCIIHexDigit else { return false }
            index += 3
        }
        return true
    }

    private static func isValidAuthority(_ value: String) -> Bool {
        guard let separator = value.range(of: "://") else { return false }
        let remainder = value[separator.upperBound...]
        let authority = remainder.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty, !authority.contains("@") else { return false }

        if authority.first == "[" {
            guard let closing = authority.firstIndex(of: "]") else { return false }
            let suffix = authority[authority.index(after: closing)...]
            if suffix.isEmpty { return true }
            guard suffix.first == ":" else { return false }
            return validPort(suffix.dropFirst())
        }

        let colonCount = authority.filter { $0 == ":" }.count
        guard colonCount <= 1 else { return false }
        guard colonCount == 1, let colon = authority.lastIndex(of: ":") else { return true }
        return validPort(authority[authority.index(after: colon)...])
    }

    private static func validPort(_ value: Substring) -> Bool {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let port = Int(value) else { return false }
        return (1...65_535).contains(port)
    }

    private static func isValidHost(_ value: String) -> Bool {
        if value.contains(":") {
            let literal = value.hasPrefix("[") && value.hasSuffix("]")
                ? String(value.dropFirst().dropLast())
                : value
            var address = in6_addr()
            return literal.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
        }
        guard !value.hasPrefix("."), !value.hasSuffix("."), !value.contains("..") else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-"
            }
        }
    }

    private static func hostVariants(for host: String) -> Set<String> {
        if host.hasPrefix("www.") {
            return [host, String(host.dropFirst(4))]
        }
        return [host, "www.\(host)"]
    }

    private static func defaultPort(for scheme: String) -> Int {
        scheme == "http" ? 80 : 443
    }
}

private extension Unicode.Scalar {
    var isASCIIHexDigit: Bool {
        ("0"..."9").contains(Character(String(self))) ||
            ("a"..."f").contains(Character(String(self).lowercased()))
    }
}

/// Owns validated website persistence and draft lifetimes.
final class WebsitePreferences {
    private static let preferenceKey = "websiteURL"
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? AppPreferences.applicationDefaults()
    }

    func currentURL() throws -> WebsiteURL {
        guard let saved = defaults.string(forKey: Self.preferenceKey) else {
            return .approvedDefault
        }
        return try WebsiteURL(saved)
    }

    func makeDraft() -> WebsiteSettingsDraft {
        WebsiteSettingsDraft(preferences: self, text: defaults.string(forKey: Self.preferenceKey) ?? WebsiteURL.approvedDefault.absoluteString)
    }

    fileprivate func save(_ url: WebsiteURL) {
        defaults.set(url.absoluteString, forKey: Self.preferenceKey)
    }
}

final class WebsiteSettingsDraft {
    private let preferences: WebsitePreferences
    private(set) var text: String

    fileprivate init(preferences: WebsitePreferences, text: String) {
        self.preferences = preferences
        self.text = text
    }

    func update(_ value: String) {
        text = value
    }

    @discardableResult
    func save() throws -> WebsiteURL {
        let normalized = try WebsiteURL(text)
        preferences.save(normalized)
        text = normalized.absoluteString
        return normalized
    }

    func cancel() {}
}

import Darwin
import Foundation

struct ResourceNetworkURLPolicy: Equatable, Sendable {
    let pinnedAllowedHosts: [String]
    private let allowedHostSet: Set<String>

    init(pinnedAllowedHosts: [String]) throws {
        guard !pinnedAllowedHosts.isEmpty else {
            throw ResourceNetworkError.invalidEndpoint
        }
        var normalized: Set<String> = []
        for candidate in pinnedAllowedHosts {
            guard let host = Self.validatedDNSHost(candidate) else {
                throw ResourceNetworkError.invalidEndpoint
            }
            normalized.insert(host)
        }
        guard !normalized.isEmpty else {
            throw ResourceNetworkError.invalidEndpoint
        }
        self.pinnedAllowedHosts = normalized.sorted()
        allowedHostSet = normalized
    }

    func validateInitialURL(_ rawValue: String) throws -> URL {
        guard Self.rawAuthorityIsASCII(rawValue),
              let url = URL(string: rawValue),
              url.baseURL == nil else {
            throw ResourceNetworkError.invalidEndpoint
        }
        do {
            return try validate(url)
        } catch {
            throw ResourceNetworkError.invalidEndpoint
        }
    }

    func validate(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.port == nil || url.port == 443 else {
            throw ResourceNetworkError.disallowedURL
        }
        guard let rawHost = url.host,
              let host = Self.validatedDNSHost(rawHost) else {
            throw ResourceNetworkError.disallowedURL
        }
        guard allowedHostSet.contains(host) else {
            throw ResourceNetworkError.disallowedHost
        }
        return url
    }

    func validateRedirect(location: String,
                          relativeTo responseURL: URL,
                          proposedRequest: URLRequest,
                          statusCode: Int) throws -> URL {
        guard [301, 302, 307, 308].contains(statusCode) else {
            throw ResourceNetworkError.redirectRejected
        }
        guard Self.rawAuthorityIsASCII(location),
              let proposedURL = proposedRequest.url,
              proposedRequest.httpMethod?.uppercased() == "GET",
              proposedRequest.httpBody == nil,
              proposedRequest.httpBodyStream == nil,
              let resolved = URL(string: location, relativeTo: responseURL)?.absoluteURL else {
            throw ResourceNetworkError.redirectRejected
        }
        let validatedResolved: URL
        let validatedProposed: URL
        do {
            validatedResolved = try validate(resolved)
            validatedProposed = try validate(proposedURL)
        } catch {
            throw ResourceNetworkError.redirectRejected
        }
        guard canonicalIdentifier(for: validatedResolved) ==
                canonicalIdentifier(for: validatedProposed) else {
            throw ResourceNetworkError.redirectRejected
        }
        return validatedResolved
    }

    func canonicalIdentifier(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? url.absoluteString.lowercased()
    }

    private static func validatedDNSHost(_ rawValue: String) -> String? {
        let host = rawValue.lowercased()
        let bytes = Array(host.utf8)
        guard !bytes.isEmpty,
              bytes.count == host.count,
              bytes.count <= 253,
              !host.hasSuffix("."),
              !host.contains("%") else { return nil }

        var ipv4 = in_addr()
        if host.withCString({ Darwin.inet_aton($0, &ipv4) }) != 0 { return nil }
        var ipv6 = in6_addr()
        if host.withCString({ Darwin.inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return nil }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  let first = label.utf8.first,
                  let last = label.utf8.last,
                  Self.isASCIIAlphanumeric(first),
                  Self.isASCIIAlphanumeric(last),
                  label.utf8.allSatisfy({ Self.isASCIIAlphanumeric($0) || $0 == 45 }) else {
                return nil
            }
        }
        return host
    }

    private static func isASCIIAlphanumeric(_ value: UInt8) -> Bool {
        (value >= 97 && value <= 122) || (value >= 48 && value <= 57)
    }

    private static func rawAuthorityIsASCII(_ rawValue: String) -> Bool {
        let authorityStart: String.Index
        if let separator = rawValue.range(of: "://") {
            authorityStart = separator.upperBound
        } else if rawValue.hasPrefix("//") {
            authorityStart = rawValue.index(rawValue.startIndex, offsetBy: 2)
        } else {
            return true
        }
        let remainder = rawValue[authorityStart...]
        let authorityEnd = remainder.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
            ?? rawValue.endIndex
        let authority = rawValue[authorityStart..<authorityEnd]
        return !authority.contains("%") &&
            authority.unicodeScalars.allSatisfy { $0.value <= 0x7f }
    }
}

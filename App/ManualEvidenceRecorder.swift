import CryptoKit
import Darwin
import Foundation

/// Opt-in, append-only diagnostics for an explicitly launched manual-acceptance session.
///
/// The recorder is inert unless the process was launched with
/// `--manual-evidence-log /absolute/path/evidence.jsonl`. It never stores query or response
/// bodies: callers may provide lengths, stable hashes, typed state and public resource IDs only.
final class ManualEvidenceRecorder: @unchecked Sendable {
    static let schemaVersion = 1
    static let shared = ManualEvidenceRecorder()

    private let lock = NSLock()
    private let processSessionID = UUID().uuidString.lowercased()
    private let processID = ProcessInfo.processInfo.processIdentifier
    private let appVersion: String
    private let appBuild: String
    private let executableSHA256: String
    private var handle: FileHandle?

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handle != nil
    }

    private init(arguments: [String] = ProcessInfo.processInfo.arguments,
                 bundle: Bundle = .main) {
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "unknown"
        appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion")
            as? String ?? "unknown"
        executableSHA256 = Self.digest(bundle.executableURL) ?? "unavailable"

        guard let flag = arguments.firstIndex(of: "--manual-evidence-log"),
              arguments.indices.contains(flag + 1) else { return }
        let rawPath = arguments[flag + 1]
        guard NSString(string: rawPath).isAbsolutePath,
              !rawPath.contains("\0") else { return }
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard let opened = Self.openPrivateAppendFile(url) else { return }
        handle = opened
        record("evidenceSessionStarted", strings: [
            "resultKind": "enabled",
            "typedReason": "explicitCommandLineOptIn"
        ])
    }

    deinit {
        flush()
        try? handle?.close()
    }

    func record(
        _ eventType: String,
        strings: [String: String] = [:],
        integers: [String: Int64] = [:],
        booleans: [String: Bool] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        var event: [String: Any] = [
            "schemaVersion": Self.schemaVersion,
            "wallTimestamp": ISO8601DateFormatter().string(from: Date()),
            "monotonicTimestamp": DispatchTime.now().uptimeNanoseconds,
            "processID": processID,
            "processSessionID": processSessionID,
            "appVersion": appVersion,
            "appBuild": appBuild,
            "executableSHA256": executableSHA256,
            "eventType": Self.safeToken(eventType)
        ]
        for (key, value) in strings {
            event[Self.safeToken(key)] = Self.bounded(value)
        }
        for (key, value) in integers {
            event[Self.safeToken(key)] = value
        }
        for (key, value) in booleans {
            event[Self.safeToken(key)] = value
        }
        guard JSONSerialization.isValidJSONObject(event),
              var data = try? JSONSerialization.data(
                withJSONObject: event, options: [.sortedKeys]
              ) else { return }
        do {
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    func recordQuery(
        _ eventType: String,
        query: String,
        queryGeneration: UInt64,
        queryKind: String,
        queryLanguage: String,
        nativeLanguage: String,
        learningLanguage: String,
        diagnosticStrings: [String: String] = [:],
        diagnosticIntegers: [String: Int64] = [:]
    ) {
        let normalized = query.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let strings = [
            "queryKind": queryKind,
            "queryLanguage": queryLanguage,
            "nativeLanguage": nativeLanguage,
            "learningLanguage": learningLanguage,
            "queryHash": Self.hash(normalized)
        ].merging(diagnosticStrings) { current, _ in current }
        let integers: [String: Int64] = [
            "queryGeneration": Int64(clamping: queryGeneration),
            "queryLength": Int64(normalized.count)
        ].merging(diagnosticIntegers) { current, _ in current }
        record(eventType, strings: strings, integers: integers)
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
    }

    static func identityHash(_ value: String) -> String {
        hash(value.precomposedStringWithCompatibilityMapping)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func digest(_ url: URL?) -> String? {
        guard let url, let source = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? source.close() }
        var digest = SHA256()
        while let data = try? source.read(upToCount: 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func openPrivateAppendFile(_ url: URL) -> FileHandle? {
        let parent = url.deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              parentInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              parentInfo.st_uid == geteuid() else { return nil }
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_uid == geteuid(),
              fchmod(descriptor, 0o600) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func bounded(_ value: String) -> String {
        String(value.replacingOccurrences(of: "\n", with: " ").prefix(512))
    }

    private static func safeToken(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
        let result = String(String.UnicodeScalarView(filtered))
        return String((result.isEmpty ? "unknown" : result).prefix(80))
    }
}

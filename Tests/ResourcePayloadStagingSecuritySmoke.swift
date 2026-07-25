import CryptoKit
import Darwin
import Foundation
import os

private struct Failure: Error { let message: String }

private struct Harness {
    var assertions = 0
    mutating func check(_ name: String, _ condition: @autoclosure () throws -> Bool) throws {
        guard try condition() else { throw Failure(message: name) }
        assertions += 1
    }
    mutating func expect(_ name: String, _ expected: ResourcePayloadDownloadError,
                          _ body: () throws -> Void) throws {
        do {
            try body()
            throw Failure(message: "\(name): unexpectedly succeeded")
        } catch let error as ResourcePayloadDownloadError {
            guard error == expected else { throw Failure(message: "\(name): wrong error \(error)") }
            assertions += 1
        }
    }
}

private let fixedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private func digest(_ value: Data) -> String {
    SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
}
private func plan(root: URL, payload: Data) throws -> ResourcePayloadDownloadPlan {
    let policy = try ResourcePayloadDownloadPolicy(
        applicationAllowedHosts: ["example.test"], applicationHardLimit: 4_096,
        diskSafetyMargin: 0, maximumRedirects: 0, requestTimeout: 1, resourceTimeout: 1
    )
    return ResourcePayloadDownloadPlan(
        resourceID: "synthetic", resourceRevision: 1,
        downloadURL: URL(string: "https://example.test/synthetic.mdx")!,
        signedFileName: "synthetic.mdx", expectedBytes: UInt64(payload.count),
        maximumBytes: UInt64(payload.count), expectedSHA256: digest(payload),
        allowedHosts: ["example.test"], stagingRoot: root, policy: policy
    )
}
private func store() -> ResourcePayloadStagingStore {
    ResourcePayloadStagingStore(operationIDFactory: { fixedID })
}

private func store(hooks: ResourcePayloadFileSystemHooks) -> ResourcePayloadStagingStore {
    ResourcePayloadStagingStore(hooks: hooks, operationIDFactory: { fixedID })
}

private func hooks(
    writeAll: (@Sendable (Int32, Data) throws -> Void)? = nil,
    synchronize: (@Sendable (Int32) throws -> Void)? = nil,
    renameNoReplaceAt: (@Sendable (Int32, String, Int32, String) throws -> Void)? = nil
) -> ResourcePayloadFileSystemHooks {
    let base = ResourcePayloadFileSystemHooks.production
    return ResourcePayloadFileSystemHooks(
        availableCapacity: base.availableCapacity,
        writeAll: writeAll ?? base.writeAll,
        synchronize: synchronize ?? base.synchronize,
        close: base.close,
        renameNoReplaceAt: renameNoReplaceAt ?? base.renameNoReplaceAt
    )
}
private func partialDirectory(_ root: URL) -> URL {
    root.appendingPathComponent(".partial-\(fixedID.uuidString.lowercased())", isDirectory: true)
}
private func verifiedDirectory(_ root: URL) -> URL {
    root.appendingPathComponent("verified-\(fixedID.uuidString.lowercased())", isDirectory: true)
}
private func statValue(_ url: URL) throws -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else { throw Failure(message: "stat failed") }
    return value
}
private func mode(_ url: URL) throws -> mode_t { try statValue(url).st_mode & 0o777 }

private func writeAll(_ descriptor: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            guard result > 0 else { throw Failure(message: "competitor write") }
            offset += result
        }
    }
}

private func createCompetitorFile(parent: Int32, component: String, contents: Data) throws {
    let descriptor = component.withCString {
        Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else { throw Failure(message: "competitor create") }
    defer { _ = Darwin.close(descriptor) }
    try writeAll(descriptor, contents)
}

@main
enum ResourcePayloadStagingSecuritySmoke {
    static func main() throws {
        var harness = Harness()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-payload-staging-security-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data("synthetic payload only".utf8)
        try testComponents(&harness)
        try testRootAndPrepare(&harness, root: root, payload: payload)
        try testPrepareAndStreamingFailures(&harness, root: root, payload: payload)
        try testFinishFailures(&harness, root: root, payload: payload)
        try testAtomicPublicationConflicts(&harness, root: root, payload: payload)
        try testDurabilityBoundary(&harness, root: root, payload: payload)
        try testIdentitySubstitution(&harness, root: root, payload: payload)
        try testDirectoryAndCleanup(&harness, root: root, payload: payload)
        try harness.check("production host remains disabled", ResourcePayloadDownloadPolicy.productionAllowedHosts.isEmpty)
        print("Resource payload staging security smoke passed (\(harness.assertions) total runtime assertions)")
    }

    private static func testComponents(_ harness: inout Harness) throws {
        for value in ["", ".", "..", "a/b", "a\\b", "/absolute", "file://x", "a\0b", "a/b/c"] {
            try harness.expect("invalid component", .invalidPathComponent) {
                try ResourcePayloadStagingStore.validatePathComponentForTesting(value)
            }
        }
        try ResourcePayloadStagingStore.validatePathComponentForTesting(".partial-11111111-2222-3333-4444-555555555555")
        try harness.check("canonical component accepted", true)
    }

    private static func testRootAndPrepare(_ harness: inout Harness, root: URL, payload: Data) throws {
        let parent = root.deletingLastPathComponent()
        let rootFile = parent.appendingPathComponent("payload-root-file")
        try Data("x".utf8).write(to: rootFile)
        defer { try? FileManager.default.removeItem(at: rootFile) }
        try harness.expect("file root rejected", .unexpectedFileType) {
            _ = try store().prepare(plan: try plan(root: rootFile, payload: payload))
        }
        let target = parent.appendingPathComponent("payload-root-target", isDirectory: true)
        let link = parent.appendingPathComponent("payload-root-link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: target); try? FileManager.default.removeItem(at: link) }
        try harness.expect("symlink root rejected", .unsafePath) {
            _ = try store().prepare(plan: try plan(root: link, payload: payload))
        }
        let normalRoot = root.appendingPathComponent("normal", isDirectory: true)
        let operation = try store().prepare(plan: try plan(root: normalRoot, payload: payload))
        let rootMode = try mode(normalRoot)
        let operationMode = try mode(partialDirectory(normalRoot))
        let payloadMode = try mode(partialDirectory(normalRoot).appendingPathComponent("payload.mdx.part"))
        try harness.check("root 0700", rootMode == 0o700)
        try harness.check("operation 0700", operationMode == 0o700)
        try harness.check("new payload 0600", payloadMode == 0o600)
        _ = try operation.append(payload, maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        let completed = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
        try harness.check("finish byte count", completed.bytes == UInt64(payload.count))
        try harness.check("finish digest", completed.digest == digest(payload))
        let finalMetadata = try statValue(operation.verifiedFile)
        let finalDirectory = try statValue(operation.verifiedFile.deletingLastPathComponent())
        try harness.check("published file inode retained", operation.publishedFileIdentity?.inode == UInt64(finalMetadata.st_ino))
        try harness.check("published directory inode retained", operation.publishedDirectoryIdentity?.inode == UInt64(finalDirectory.st_ino))
        try harness.check("published file link count one", finalMetadata.st_nlink == 1)
        operation.cleanup()
        try harness.check("published cleanup preserves verified file",
                          FileManager.default.fileExists(atPath: operation.verifiedFile.path))
    }

    private static func prepared(_ root: URL, payload: Data,
                                 hooks customHooks: ResourcePayloadFileSystemHooks? = nil) throws -> ResourcePayloadStagingOperation {
        let operation = try (customHooks.map(store(hooks:)) ?? store()).prepare(plan: try plan(root: root, payload: payload))
        _ = try operation.append(payload, maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        return operation
    }

    private static func testPrepareAndStreamingFailures(_ harness: inout Harness,
                                                         root: URL, payload: Data) throws {
        let missingRoot = root.appendingPathComponent("missing-root", isDirectory: true)
        let missing = try store().prepare(plan: try plan(root: missingRoot, payload: payload))
        try harness.check("missing root is created", FileManager.default.fileExists(atPath: missingRoot.path))
        missing.cleanup()

        let unsafeRoot = root.appendingPathComponent("unsafe-root", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeRoot, withIntermediateDirectories: true)
        guard chmod(unsafeRoot.path, 0o777) == 0 else { throw Failure(message: "chmod setup") }
        try harness.expect("group writable root rejected", .permissionDenied) {
            _ = try store().prepare(plan: try plan(root: unsafeRoot, payload: payload))
        }

        let collisionRoot = root.appendingPathComponent("operation-collision", isDirectory: true)
        try FileManager.default.createDirectory(at: collisionRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partialDirectory(collisionRoot), withIntermediateDirectories: false)
        try harness.expect("operation collision", .conflict) {
            _ = try store().prepare(plan: try plan(root: collisionRoot, payload: payload))
        }

        let fileCollisionRoot = root.appendingPathComponent("operation-file", isDirectory: true)
        try FileManager.default.createDirectory(at: fileCollisionRoot, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: partialDirectory(fileCollisionRoot))
        try harness.expect("operation file collision", .conflict) {
            _ = try store().prepare(plan: try plan(root: fileCollisionRoot, payload: payload))
        }

        let streamRoot = root.appendingPathComponent("stream", isDirectory: true)
        let operation = try store().prepare(plan: try plan(root: streamRoot, payload: payload))
        let midpoint = payload.count / 2
        _ = try operation.append(Data(payload.prefix(midpoint)), maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        _ = try operation.append(Data(), maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        _ = try operation.append(Data(payload.dropFirst(midpoint)), maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        let complete = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
        try harness.check("multi-chunk and empty chunk exact bytes", complete.bytes == UInt64(payload.count))
        try harness.expect("append after finish", .writeFailure) {
            _ = try operation.append(Data("x".utf8), maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        }
        operation.cleanup()

        let cancelled = try store().prepare(plan: try plan(root: root.appendingPathComponent("cancelled", isDirectory: true), payload: payload))
        cancelled.cleanup()
        cancelled.cleanup()
        try harness.expect("append after cleanup", .writeFailure) {
            _ = try cancelled.append(Data("x".utf8), maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        }

        let tooLarge = try store().prepare(plan: try plan(root: root.appendingPathComponent("too-large", isDirectory: true), payload: payload))
        try harness.expect("limit plus one rejected before write", .responseTooLarge) {
            _ = try tooLarge.append(payload + Data("x".utf8), maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        }
        tooLarge.cleanup()

        let failedWrite = hooks(writeAll: { _, _ in throw ResourcePayloadDownloadError.writeFailure })
        let failed = try store(hooks: failedWrite).prepare(plan: try plan(root: root.appendingPathComponent("write-failure", isDirectory: true), payload: payload))
        try harness.expect("write failure remains exact", .writeFailure) {
            _ = try failed.append(payload, maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        }
        try harness.expect("append after write failure", .writeFailure) {
            _ = try failed.append(payload, maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
        }
        failed.cleanup()
    }

    private static func testFinishFailures(_ harness: inout Harness,
                                           root: URL, payload: Data) throws {
        do {
            let operation = try prepared(root.appendingPathComponent("size-mismatch", isDirectory: true), payload: payload)
            try harness.expect("expected size mismatch", .sizeMismatch) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count + 1), expectedSHA256: digest(payload))
            }
            operation.cleanup()
        }
        do {
            let operation = try prepared(root.appendingPathComponent("hash-mismatch", isDirectory: true), payload: payload)
            try harness.expect("expected hash mismatch", .hashMismatch) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(Data("other".utf8)))
            }
            operation.cleanup()
        }
        do {
            let child = root.appendingPathComponent("fd-size-mismatch", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let partial = partialDirectory(child).appendingPathComponent("payload.mdx.part")
            guard truncate(partial.path, 0) == 0 else { throw Failure(message: "truncate setup") }
            try harness.expect("fd tracked size mismatch", .identityChanged) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            operation.cleanup()
        }
        do {
            let child = root.appendingPathComponent("payload-mode", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let partial = partialDirectory(child).appendingPathComponent("payload.mdx.part")
            guard chmod(partial.path, 0o644) == 0 else { throw Failure(message: "chmod payload") }
            try harness.expect("tampered payload mode", .unexpectedPermissions) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            try harness.check("mode tamper has no verified directory",
                              !FileManager.default.fileExists(atPath: verifiedDirectory(child).path))
            operation.cleanup()
        }
        for (name, failureCall) in [("file-fsync", 1), ("operation-fsync", 2)] {
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let failingHooks = hooks(synchronize: { descriptor in
                let current = calls.withLock { value in
                    value += 1
                    return value
                }
                if current == failureCall { throw ResourcePayloadDownloadError.durabilityFailure }
                try ResourcePayloadFileSystemHooks.production.synchronize(descriptor)
            })
            let operation = try prepared(root.appendingPathComponent(name, isDirectory: true), payload: payload, hooks: failingHooks)
            try harness.expect("\(name) exact durability error", .durabilityFailure) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            operation.cleanup()
        }
        do {
            let crossDevice = hooks(renameNoReplaceAt: { _, _, _, _ in throw ResourcePayloadDownloadError.crossDevicePublication })
            let operation = try prepared(root.appendingPathComponent("cross-device", isDirectory: true), payload: payload, hooks: crossDevice)
            try harness.expect("cross-device publication", .crossDevicePublication) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            operation.cleanup()
        }
        do {
            let base = ResourcePayloadFileSystemHooks.production
            let mutateFinal = hooks(renameNoReplaceAt: { sourceFD, source, destinationFD, destination in
                try base.renameNoReplaceAt(sourceFD, source, destinationFD, destination)
                guard destination == "payload.mdx" else { return }
                _ = destination.withCString { Darwin.unlinkat(destinationFD, $0, 0) }
                let replacement = destination.withCString {
                    Darwin.openat(destinationFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
                }
                guard replacement >= 0 else { throw ResourcePayloadDownloadError.ioFailure }
                defer { _ = Darwin.close(replacement) }
                _ = Darwin.write(replacement, "x", 1)
            })
            let operation = try prepared(root.appendingPathComponent("final-substitution", isDirectory: true), payload: payload, hooks: mutateFinal)
            try harness.expect("final entry identity mismatch", .identityChanged) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            operation.cleanup()
        }
    }

    private static func testAtomicPublicationConflicts(_ harness: inout Harness,
                                                        root: URL, payload: Data) throws {
        let competitor = Data("competitor payload".utf8)
        do {
            let child = root.appendingPathComponent("inner-static-file", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let target = partialDirectory(child).appendingPathComponent("payload.mdx")
            try competitor.write(to: target)
            let before = try statValue(target)
            try harness.expect("inner static file conflict", .conflict) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            try harness.check("inner static file untouched", try Data(contentsOf: target) == competitor)
            try harness.check("inner static file inode untouched", try statValue(target).st_ino == before.st_ino)
            operation.cleanup()
            try harness.check("inner static file survives cleanup", FileManager.default.fileExists(atPath: target.path))
        }
        do {
            let child = root.appendingPathComponent("inner-static-directory", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let target = partialDirectory(child).appendingPathComponent("payload.mdx", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let before = try statValue(target)
            try harness.expect("inner static directory conflict", .conflict) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            try harness.check("inner static directory inode untouched", try statValue(target).st_ino == before.st_ino)
            operation.cleanup()
            try harness.check("inner static directory survives cleanup", FileManager.default.fileExists(atPath: target.path))
        }
        do {
            let child = root.appendingPathComponent("inner-race", isDirectory: true)
            let armed = OSAllocatedUnfairLock(initialState: true)
            let base = ResourcePayloadFileSystemHooks.production
            let racingHooks = hooks(renameNoReplaceAt: { sourceFD, source, destinationFD, destination in
                let inject = armed.withLock { armed in
                    guard armed, destination == "payload.mdx" else { return false }
                    armed = false
                    return true
                }
                if inject { try createCompetitorFile(parent: destinationFD, component: destination, contents: competitor) }
                try base.renameNoReplaceAt(sourceFD, source, destinationFD, destination)
            })
            let operation = try prepared(child, payload: payload, hooks: racingHooks)
            let target = partialDirectory(child).appendingPathComponent("payload.mdx")
            try harness.expect("inner no-replace race", .conflict) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            let before = try statValue(target)
            try harness.check("inner race content untouched", try Data(contentsOf: target) == competitor)
            try harness.check("inner race did not publish source", try Data(contentsOf: target) != payload)
            operation.cleanup()
            try harness.check("inner race target survives cleanup", FileManager.default.fileExists(atPath: target.path))
            try harness.check("inner race inode survives cleanup", try statValue(target).st_ino == before.st_ino)
        }
        do {
            let child = root.appendingPathComponent("outer-static-file", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let target = verifiedDirectory(child)
            try competitor.write(to: target)
            let before = try statValue(target)
            try harness.expect("outer static file conflict", .conflict) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            try harness.check("outer static file untouched", try Data(contentsOf: target) == competitor)
            try harness.check("outer static file inode untouched", try statValue(target).st_ino == before.st_ino)
            operation.cleanup()
            try harness.check("outer static file survives cleanup", FileManager.default.fileExists(atPath: target.path))
        }
        do {
            let child = root.appendingPathComponent("outer-static-directory", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let target = verifiedDirectory(child)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let before = try statValue(target)
            try harness.expect("outer static directory conflict", .conflict) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            try harness.check("outer static directory inode untouched", try statValue(target).st_ino == before.st_ino)
            operation.cleanup()
            try harness.check("outer static directory survives cleanup", FileManager.default.fileExists(atPath: target.path))
        }
        do {
            let child = root.appendingPathComponent("outer-race", isDirectory: true)
            let armed = OSAllocatedUnfairLock(initialState: true)
            let base = ResourcePayloadFileSystemHooks.production
            let racingHooks = hooks(renameNoReplaceAt: { sourceFD, source, destinationFD, destination in
                let inject = armed.withLock { armed in
                    guard armed, destination.hasPrefix("verified-") else { return false }
                    armed = false
                    return true
                }
                if inject { try createCompetitorFile(parent: destinationFD, component: destination, contents: competitor) }
                try base.renameNoReplaceAt(sourceFD, source, destinationFD, destination)
            })
            let operation = try prepared(child, payload: payload, hooks: racingHooks)
            let target = verifiedDirectory(child)
            try harness.expect("outer no-replace race", .conflict) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            let before = try statValue(target)
            try harness.check("outer race content untouched", try Data(contentsOf: target) == competitor)
            try harness.check("outer race did not publish operation", try Data(contentsOf: target) != payload)
            operation.cleanup()
            try harness.check("outer race target survives cleanup", FileManager.default.fileExists(atPath: target.path))
            try harness.check("outer race inode survives cleanup", try statValue(target).st_ino == before.st_ino)
        }
    }

    private static func testDurabilityBoundary(_ harness: inout Harness,
                                               root: URL, payload: Data) throws {
        do {
            let child = root.appendingPathComponent("operation-fsync-boundary", isDirectory: true)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let failingHooks = hooks(synchronize: { descriptor in
                let call = calls.withLock { value in value += 1; return value }
                if call == 2 { throw ResourcePayloadDownloadError.durabilityFailure }
                try ResourcePayloadFileSystemHooks.production.synchronize(descriptor)
            })
            let operation = try prepared(child, payload: payload, hooks: failingHooks)
            try harness.expect("operation fsync blocks outer publication", .durabilityFailure) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            try harness.check("operation fsync leaves no verified target",
                              !FileManager.default.fileExists(atPath: verifiedDirectory(child).path))
            operation.cleanup()
            try harness.check("operation fsync cleanup removes operation directory",
                              !FileManager.default.fileExists(atPath: partialDirectory(child).path))
        }
        do {
            let child = root.appendingPathComponent("root-fsync-boundary", isDirectory: true)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let failingHooks = hooks(synchronize: { descriptor in
                let call = calls.withLock { value in value += 1; return value }
                if call == 3 { throw ResourcePayloadDownloadError.durabilityFailure }
                try ResourcePayloadFileSystemHooks.production.synchronize(descriptor)
            })
            let operation = try prepared(child, payload: payload, hooks: failingHooks)
            try harness.expect("root fsync reports durability failure", .durabilityFailure) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            let final = operation.verifiedFile
            let finalMetadata = try statValue(final)
            let directoryMetadata = try statValue(final.deletingLastPathComponent())
            try harness.check("root fsync retains verified file", FileManager.default.fileExists(atPath: final.path))
            try harness.check("root fsync retains verified bytes", try Data(contentsOf: final) == payload)
            try harness.check("root fsync retains verified size", finalMetadata.st_size == payload.count)
            try harness.check("root fsync retains streamed inode", operation.publishedFileIdentity?.inode == UInt64(finalMetadata.st_ino))
            try harness.check("root fsync retains operation directory inode", operation.publishedDirectoryIdentity?.inode == UInt64(directoryMetadata.st_ino))
            try harness.expect("append after uncertain publication", .writeFailure) {
                _ = try operation.append(Data("x".utf8), maximumBytes: UInt64(payload.count), expectedBytes: UInt64(payload.count))
            }
            try harness.expect("finish after uncertain publication", .stagingFailure) {
                _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload))
            }
            operation.cleanup()
            operation.cleanup()
            try harness.check("uncertain cleanup retains verified file", FileManager.default.fileExists(atPath: final.path))
            try harness.check("uncertain cleanup retains verified bytes", try Data(contentsOf: final) == payload)
        }
    }

    private static func testIdentitySubstitution(_ harness: inout Harness, root: URL, payload: Data) throws {
        do {
            let child = root.appendingPathComponent("replace-file", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let partial = partialDirectory(child).appendingPathComponent("payload.mdx.part")
            try FileManager.default.removeItem(at: partial)
            try Data("replacement".utf8).write(to: partial)
            try harness.expect("partial replacement", .identityChanged) { _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload)) }
            operation.cleanup()
        }
        do {
            let child = root.appendingPathComponent("replace-symlink", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let partial = partialDirectory(child).appendingPathComponent("payload.mdx.part")
            let target = child.appendingPathComponent("target")
            try Data("target".utf8).write(to: target)
            try FileManager.default.removeItem(at: partial)
            try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: target)
            try harness.expect("partial symlink", .identityChanged) { _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload)) }
            operation.cleanup()
        }
        do {
            let child = root.appendingPathComponent("hardlink", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let partial = partialDirectory(child).appendingPathComponent("payload.mdx.part")
            guard Darwin.link(partial.path, partialDirectory(child).appendingPathComponent("payload-alias").path) == 0 else { throw Failure(message: "hardlink setup") }
            try harness.expect("partial hardlink", .unexpectedLinkCount) { _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload)) }
            operation.cleanup()
        }
        do {
            let child = root.appendingPathComponent("deleted", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            try FileManager.default.removeItem(at: partialDirectory(child).appendingPathComponent("payload.mdx.part"))
            try harness.expect("partial missing", .identityChanged) { _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload)) }
            operation.cleanup()
        }
    }

    private static func testDirectoryAndCleanup(_ harness: inout Harness, root: URL, payload: Data) throws {
        do {
            let child = root.appendingPathComponent("directory-substitution", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            let original = partialDirectory(child)
            try FileManager.default.moveItem(at: original, to: child.appendingPathComponent("moved", isDirectory: true))
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            try harness.expect("operation directory substitution", .identityChanged) { _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload)) }
            operation.cleanup()
        }
        do {
            let child = root.appendingPathComponent("verified-conflict", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            try FileManager.default.createDirectory(at: child.appendingPathComponent("verified-\(fixedID.uuidString.lowercased())"), withIntermediateDirectories: false)
            try harness.expect("verified target exists", .conflict) { _ = try operation.finish(expectedBytes: UInt64(payload.count), expectedSHA256: digest(payload)) }
            operation.cleanup()
        }
        do {
            let child = root.appendingPathComponent("unknown-cleanup", isDirectory: true)
            let operation = try prepared(child, payload: payload)
            try Data("unknown".utf8).write(to: partialDirectory(child).appendingPathComponent("unknown"))
            operation.cleanup()
            try harness.check("unknown entry preserves operation directory", FileManager.default.fileExists(atPath: partialDirectory(child).path))
        }
    }
}

import Darwin
import Foundation

final class DictionaryCatalogStore {
    static let catalogFileName = "catalog-v1.json"
    static let backupFileName = "catalog-v1.backup.json"

    let directoryURL: URL
    let catalogURL: URL
    let backupURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directoryURL: URL = DictionaryCatalogStore.defaultDirectoryURL(),
         fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        catalogURL = directoryURL.appendingPathComponent(Self.catalogFileName)
        backupURL = directoryURL.appendingPathComponent(Self.backupFileName)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("LocalDictionary/Catalog", isDirectory: true)
    }

    func load() -> DictionaryCatalog {
        if let catalog = decodeCatalog(at: catalogURL) { return catalog }
        if let backup = decodeCatalog(at: backupURL) { return backup }
        return .empty()
    }

    func save(_ catalog: DictionaryCatalog) throws {
        let validated = try catalog.validated()
        let data = try encoder.encode(validated)
        try fileManager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true)

        let operationID = UUID().uuidString
        let backupTemporaryURL = directoryURL
            .appendingPathComponent(".\(Self.backupFileName).\(operationID).tmp")
        let catalogTemporaryURL = directoryURL
            .appendingPathComponent(".\(Self.catalogFileName).\(operationID).tmp")
        defer {
            try? fileManager.removeItem(at: backupTemporaryURL)
            try? fileManager.removeItem(at: catalogTemporaryURL)
        }

        try writeAndSynchronize(data, to: backupTemporaryURL)
        try writeAndSynchronize(data, to: catalogTemporaryURL)
        try replaceAtomically(source: backupTemporaryURL, destination: backupURL)
        try replaceAtomically(source: catalogTemporaryURL, destination: catalogURL)
        synchronizeDirectory()
    }

    private func decodeCatalog(at url: URL) -> DictionaryCatalog? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(DictionaryCatalog.self, from: data),
              let validated = try? decoded.validated() else { return nil }
        return validated
    }

    private func writeAndSynchronize(_ data: Data, to url: URL) throws {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func replaceAtomically(source: URL, destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func synchronizeDirectory() {
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        _ = Darwin.fsync(descriptor)
    }
}

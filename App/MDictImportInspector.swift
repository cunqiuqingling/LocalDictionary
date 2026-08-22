import CryptoKit
import Foundation

struct MDictImportInspector: Sendable {
    private static let maximumHeaderBytes = 4 * 1024 * 1024

    func inspect(_ selectedURL: URL) -> DictionaryImportInspectionOutcome {
        do {
            return .success(try previews(for: selectedURL))
        } catch let error as DictionaryImportError {
            return .failure(error)
        } catch {
            return .failure(.inspectionFailed(error.localizedDescription))
        }
    }

    func previews(for selectedURL: URL) throws -> [DictionaryImportPreview] {
        let resourceValues = try selectedURL.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues.isDirectory != true,
              selectedURL.pathExtension.caseInsensitiveCompare("mdx") == .orderedSame else {
            throw DictionaryImportError.invalidSelection
        }
        let mdxURLs = [selectedURL]

        guard !mdxURLs.isEmpty else { throw DictionaryImportError.noMDXFiles }
        return try mdxURLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(makePreview(for:))
    }

    func sha256(of url: URL,
                cancellationCheck: @Sendable () -> Bool = { false }) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw DictionaryImportError.sourceMissing(url.lastPathComponent)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DictionaryImportError.unreadableFile(url.lastPathComponent)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            if cancellationCheck() { throw DictionaryImportError.cancelled }
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func makePreview(for mdxURL: URL) throws -> DictionaryImportPreview {
        let mdxSize = try validatedRegularFileSize(mdxURL, extension: "mdx")
        let header = try readHeaderSummary(from: mdxURL, fileSize: mdxSize)
        let digest = try sha256(of: mdxURL)
        // M23 supports one MDX payload only. Do not inspect sibling MDD files or infer resources.
        let candidates: [DictionaryMDDCandidate] = []
        let modifiedAt = try? mdxURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let automatic = candidates.count == 1 ? Set([candidates[0].id]) : []
        let fallbackName = mdxURL.deletingPathExtension().lastPathComponent
        let title = header.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictionaryImportPreview(
            sourceMDXURL: mdxURL,
            displayName: title?.isEmpty == false ? title! : fallbackName,
            originalFileName: mdxURL.lastPathComponent,
            mdxFileSize: mdxSize,
            sourceModifiedAt: modifiedAt,
            header: header,
            mdxSHA256: digest,
            mddCandidates: candidates,
            automaticallySelectedMDDIDs: automatic
        )
    }

    private func validatedRegularFileSize(_ url: URL, extension expected: String) throws -> UInt64 {
        let fileManager = FileManager.default
        guard url.pathExtension.caseInsensitiveCompare(expected) == .orderedSame else {
            throw DictionaryImportError.invalidSelection
        }
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              fileManager.isReadableFile(atPath: url.path),
              let size = values.fileSize, size > 0 else {
            throw DictionaryImportError.unreadableFile(url.lastPathComponent)
        }
        return UInt64(size)
    }

    private func readHeaderSummary(from url: URL, fileSize: UInt64) throws -> MDictHeaderSummary {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sizeData = try readExactly(4, from: handle)
        let headerSize = sizeData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard headerSize > 0 else { throw DictionaryImportError.invalidMDX("文件头长度为零") }
        guard headerSize <= Self.maximumHeaderBytes else {
            throw DictionaryImportError.headerTooLarge
        }
        guard UInt64(headerSize) + 8 <= fileSize else {
            throw DictionaryImportError.invalidMDX("文件头超出文件范围")
        }
        let headerData = try readExactly(Int(headerSize), from: handle)
        guard let headerText = decodeHeader(headerData) else {
            throw DictionaryImportError.invalidMDX("无法解码 UTF-16 文件头")
        }
        let attributes = try parseHeaderAttributes(headerText)
        let version = attributes["GeneratedByEngineVersion"]
            ?? attributes["RequiredEngineVersion"] ?? "未知"
        let encoding = attributes["Encoding"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let encryptionText = attributes["Encrypted"]?.lowercased() ?? "no"
        let encrypted = !["", "no", "none", "0", "false"].contains(encryptionText)
        let compression = try compressionStatus(
            attributes: attributes,
            version: Double(version),
            headerSize: UInt64(headerSize),
            fileSize: fileSize,
            handle: handle
        )
        return MDictHeaderSummary(
            title: attributes["Title"] ?? attributes["BookName"],
            engineVersion: version,
            encoding: encoding?.isEmpty == false ? encoding! : "UTF-8（默认）",
            compression: compression,
            isEncrypted: encrypted
        )
    }

    private func compressionStatus(attributes: [String: String], version: Double?,
                                   headerSize: UInt64, fileSize: UInt64,
                                   handle: FileHandle) throws -> MDictCompressionStatus {
        for key in ["Compressed", "Compression", "Compact"] {
            guard let raw = attributes[key]?.lowercased() else { continue }
            if ["yes", "true", "1", "zlib", "lzo"].contains(raw) { return .compressed }
            if ["no", "false", "0", "none"].contains(raw) { return .uncompressed }
        }
        guard let version else { return .unknown }
        let keyBlockStart = headerSize + 8
        let markerOffset: UInt64
        if version >= 2.0 {
            markerOffset = keyBlockStart + 44
        } else {
            guard keyBlockStart + 16 <= fileSize else { return .unknown }
            try handle.seek(toOffset: keyBlockStart + 8)
            let infoSizeData = try readExactly(4, from: handle)
            let infoSize = infoSizeData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            markerOffset = keyBlockStart + 16 + UInt64(infoSize)
        }
        guard markerOffset < fileSize else { return .unknown }
        try handle.seek(toOffset: markerOffset)
        guard let marker = try handle.read(upToCount: 1)?.first else { return .unknown }
        switch marker {
        case 0: return .uncompressed
        case 1, 2: return .compressed
        default: return .unknown
        }
    }

    private func decodeHeader(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [.utf16LittleEndian, .utf16BigEndian, .utf8]
        for encoding in encodings {
            guard var text = String(data: data, encoding: encoding) else { continue }
            text = text.replacingOccurrences(of: "\u{0}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("<") { return text }
        }
        return nil
    }

    private func parseHeaderAttributes(_ text: String) throws -> [String: String] {
        guard let data = text.data(using: .utf8) else {
            throw DictionaryImportError.invalidMDX("文件头不是有效文本")
        }
        let delegate = HeaderXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        guard !delegate.attributes.isEmpty else {
            throw DictionaryImportError.invalidMDX("缺少 MDict 元数据")
        }
        return delegate.attributes
    }

    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw DictionaryImportError.invalidMDX("文件意外结束")
        }
        return data
    }
}

private final class HeaderXMLDelegate: NSObject, XMLParserDelegate {
    var attributes: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard attributes.isEmpty else { return }
        attributes = attributeDict
    }
}

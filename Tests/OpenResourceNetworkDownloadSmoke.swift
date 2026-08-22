import Foundation

@main
struct OpenResourceNetworkDownloadSmoke {
    static func main() async throws {
        let resource = BundledOpenResourceCatalog.freeDictEnglishChinese
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LocalDictionary-freedict-network-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = try ResourcePayloadDownloadPolicy(
            applicationAllowedHosts: ["download.freedict.org"],
            applicationHardLimit: 4 * 1024 * 1024,
            diskSafetyMargin: 8 * 1024 * 1024,
            maximumRedirects: 0,
            requestTimeout: 30,
            // Match the production payload policy. The official FreeDict host can
            // legitimately take several minutes even for this fixed 1.67 MB archive.
            resourceTimeout: 1_800
        )
        let result = try await ResourcePayloadDownloadCoordinator(
            policy: policy, stagingRoot: root
        ).download(starter: resource)
        guard result.resourceID == resource.resourceID,
              result.actualByteCount == resource.downloadBytes,
              result.verifiedSHA256 == resource.sha256,
              result.payloadComponent ==
                OpenResourceInstallationIdentity.starDictSourceComponent,
              result.installationIdentity.formatterIdentifier ==
                DictionaryFormatterIdentifier.freeDictStarDictV1 else {
            fatalError("fixed official download identity mismatch")
        }
        let values = try result.verifiedFileURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.fileSize == Int(resource.downloadBytes),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            fatalError("verified staging file mismatch")
        }
        let receiptURL = result.verifiedFileURL.deletingLastPathComponent()
            .appendingPathComponent(result.sidecarComponent)
        let receipt = try OpenResourceInstallationSidecar.decode(Data(contentsOf: receiptURL))
        guard receipt.resourceID == resource.resourceID,
              receipt.payloadSHA256 == resource.sha256,
              receipt.payloadRelativePath == result.payloadComponent else {
            fatalError("verified staging receipt mismatch")
        }
        print("Official FreeDict network download smoke passed (\(result.actualByteCount) bytes).")
    }
}

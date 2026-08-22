import Foundation

private enum DiscoverySmokeFailure: Error { case failed(String) }

private func expect(_ condition: @autoclosure () -> Bool,
                    _ message: String) throws {
    guard condition() else { throw DiscoverySmokeFailure.failed(message) }
}

@main
private enum OfficialOpenResourceDiscoverySmoke {
    static func main() async throws {
        if CommandLine.arguments.dropFirst().contains("--live") {
            let live = try await OfficialOpenResourceDiscoveryClient().discover(
                nativeLanguageCode: "zh-Hans", learningLanguageCode: "en"
            )
            try expect(live.count >= 2,
                       "official zh/en discovery returned fewer than two bilingual resources")
            try expect(live.allSatisfy {
                $0.isRecommended(nativeLanguageCode: "zh-Hans", learningLanguageCode: "en")
            }, "official response included a resource unrelated to the active pair")
            print("Live official discovery passed: " +
                  live.map(\.resourceID).joined(separator: ", "))
            return
        }
        let sha512 = String(repeating: "a", count: 128)
        let catalog = """
        [
          {"edition":"2026.01","headwords":"100","name":"eng-zho","status":"stable",
           "releases":[{"URL":"https://download.freedict.org/dictionaries/eng-zho/2026.01/freedict-eng-zho-2026.01.stardict.tar.xz","checksum":"\(sha512)","date":"2026-08-20","platform":"stardict","size":"1000","version":"2026.01"}]},
          {"edition":"2026.01","headwords":"90","name":"zho-eng","status":"stable",
           "releases":[{"URL":"https://download.freedict.org/dictionaries/zho-eng/2026.01/freedict-zho-eng-2026.01.stardict.tar.xz","checksum":"\(sha512)","date":"2026-08-20","platform":"stardict","size":"900","version":"2026.01"}]},
          {"edition":"2026.02","headwords":"80","name":"deu-eng","status":"stable",
           "releases":[{"URL":"https://download.freedict.org/dictionaries/deu-eng/2026.02/freedict-deu-eng-2026.02.stardict.tar.xz","checksum":"\(sha512)","date":"2026-08-21","platform":"stardict","size":"800","version":"2026.02"}]},
          {"edition":"2026.02","headwords":"70","name":"eng-deu","status":"stable",
           "releases":[{"URL":"https://download.freedict.org/dictionaries/eng-deu/2026.02/freedict-eng-deu-2026.02.stardict.tar.xz","checksum":"\(sha512)","date":"2026-08-21","platform":"stardict","size":"700","version":"2026.02"}]}
        ]
        """.data(using: .utf8)!

        let chineseEnglish = try OfficialOpenResourceDiscoveryClient.resources(
            from: catalog, nativeLanguageCode: "zh-Hans", learningLanguageCode: "en"
        )
        try expect(chineseEnglish.count == 3,
                   "zh/en must expose both official directions plus CC-CEDICT")
        try expect(Set(chineseEnglish.map(\.resourceID)) == Set([
            "org.freedict.live.eng-zho", "org.freedict.live.zho-eng",
            "org.cc-cedict.zh-en.live"
        ]), "zh/en matching returned a static or unrelated resource")
        try expect(chineseEnglish.allSatisfy {
            $0.isRecommended(nativeLanguageCode: "zh-Hans", learningLanguageCode: "en")
        }, "live zh/en matches were not marked relevant")

        let germanEnglish = try OfficialOpenResourceDiscoveryClient.resources(
            from: catalog, nativeLanguageCode: "de", learningLanguageCode: "en"
        )
        try expect(Set(germanEnglish.map(\.resourceID)) == Set([
            "org.freedict.live.deu-eng", "org.freedict.live.eng-deu"
        ]), "de/en did not follow the current language pair")
        try expect(germanEnglish.allSatisfy {
            $0.isRecommended(nativeLanguageCode: "de", learningLanguageCode: "en")
        }, "future language pair recommendation was hard-coded to Chinese")

        let downloadedSHA = String(repeating: "b", count: 64)
        let freeDict = chineseEnglish.first { $0.resourceID.contains("eng-zho") }!
            .recordingDownloadedPayload(bytes: 1_234, sha256: downloadedSHA)
        try expect(freeDict.downloadBytes == 1_234 && freeDict.sha256 == downloadedSHA &&
                   freeDict.officialDigestAlgorithm == "SHA-512" &&
                   freeDict.officialDigest == sha512,
                   "official upstream digest was not preserved")

        let cedict = chineseEnglish.first { $0.resourceID == "org.cc-cedict.zh-en.live" }!
            .recordingDownloadedPayload(bytes: 4_321, sha256: downloadedSHA)
        try expect(cedict.officialDigestAlgorithm == "SHA-256" &&
                   cedict.officialDigest == downloadedSHA,
                   "resource without an upstream checksum did not record its local payload")
        try expect(cedict.downloadURL.host == "cc-cedict.org" &&
                   cedict.officialDownloadPage.host == "cc-cedict.org",
                   "live CC-CEDICT did not use the official project export endpoint")

        let identity = try OpenResourceInstallationIdentity(
            starter: freeDict,
            dictionaryID: "00000000-0000-0000-0000-000000000123"
        )
        let receipt = OpenResourceInstallationSidecar(
            identity: identity,
            sourceURL: freeDict.downloadURL.absoluteString,
            officialDigestAlgorithm: freeDict.officialDigestAlgorithm,
            officialDigest: freeDict.officialDigest,
            transformerVersion: freeDict.transformerVersion,
            outputSchemaVersion: freeDict.outputSchemaVersion,
            outputPublicationID: "10000000-0000-0000-0000-000000000123",
            outputSHA256: String(repeating: "c", count: 64),
            outputIntegrityStatus: "ok"
        )
        let roundTrip = try OpenResourceInstallationSidecar.decode(receipt.encodedData())
        try expect(roundTrip.resourceID == freeDict.resourceID,
                   "live official receipt did not survive restart validation")
        try expect(!LiveOfficialOpenResourcePolicy.accepts(
            resourceID: freeDict.resourceID,
            formatterIdentifier: freeDict.transformerIdentifier,
            sourceURL: "https://example.com/not-official.tar.xz"
        ), "live identity accepted an unrelated download host")

        print("Official open-resource discovery smoke passed.")
    }
}

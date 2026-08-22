import Darwin
import Foundation

private enum EvidenceSmokeError: Error { case failed(String) }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw EvidenceSmokeError.failed(message) }
}

@main
private enum ManualEvidenceRecorderSmoke {
    static func main() throws {
        let mode = ProcessInfo.processInfo.environment["EVIDENCE_SMOKE_MODE"] ?? "off"
        if mode == "off" {
            try require(!ManualEvidenceRecorder.shared.isEnabled,
                        "recorder activated without explicit command-line flag")
            print("Manual Evidence default-off smoke: PASS")
            return
        }
        try require(ManualEvidenceRecorder.shared.isEnabled,
                    "explicit evidence flag did not activate recorder")
        let privateText = "PRIVATE_QUERY_BODY_SHOULD_NEVER_APPEAR"
        ManualEvidenceRecorder.shared.recordQuery(
            "querySubmitted", query: privateText, queryGeneration: 7,
            queryKind: "sentence", queryLanguage: "zh-Hans",
            nativeLanguage: "zh-Hans", learningLanguage: "en",
            diagnosticStrings: [
                "queryRelation": "mixedNativeDominant",
                "dominantLanguage": "zh-Hans",
                "nativeCoverageBucket": "high",
                "learningCoverageBucket": "low",
                "classifierConfidenceBucket": "high"
            ],
            diagnosticIntegers: ["hanCharacterCount": 24, "latinTokenCount": 5]
        )
        ManualEvidenceRecorder.shared.record("aiResultPresented", strings: [
            "provider": "fixture-provider",
            "model": "fixture-model",
            "responseKind": "plainTextSuccess",
            "resultKind": "success"
        ], integers: ["responseLength": 42], booleans: ["safeVisibleContent": true])
        ManualEvidenceRecorder.shared.flush()

        guard let flag = CommandLine.arguments.firstIndex(of: "--manual-evidence-log"),
              flag + 1 < CommandLine.arguments.count else {
            throw EvidenceSmokeError.failed("missing test log argument")
        }
        let path = CommandLine.arguments[flag + 1]
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(decoding: data, as: UTF8.self)
        try require(!text.contains(privateText), "private query body leaked")
        let lines = text.split(separator: "\n")
        try require(lines.count == 3, "unexpected JSONL event count")
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            try require(object?["schemaVersion"] as? Int == 1,
                        "missing evidence schema version")
            try require(object?["processSessionID"] as? String != nil,
                        "missing process session identity")
            try require(object?["eventType"] as? String != nil,
                        "missing event type")
        }
        let query = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        try require((query?["queryHash"] as? String)?.count == 64 &&
                    query?["queryLength"] as? Int == privateText.count &&
                    query?["queryRelation"] as? String == "mixedNativeDominant" &&
                    query?["hanCharacterCount"] as? Int == 24,
                    "query privacy identity missing")
        var info = stat()
        try require(lstat(path, &info) == 0 &&
                    info.st_mode & mode_t(0o777) == mode_t(0o600) &&
                    info.st_nlink == 1,
                    "evidence file permissions/identity are unsafe")
        print("Manual Evidence JSONL/privacy smoke: PASS")
    }
}

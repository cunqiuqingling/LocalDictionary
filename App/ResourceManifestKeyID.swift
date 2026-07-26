import Foundation

/// Shared, ASCII-only key identifier grammar for manifest state, signatures, and immutable
/// open-resource receipts. Keeping it in a dependency-light file lets Catalog validation use the
/// exact same rule without pulling verification or persistence code into every smoke target.
enum ResourceManifestKeyID {
    static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), bytes.count == value.count else { return false }
        return bytes.allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }
}

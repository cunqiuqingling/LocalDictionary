import Foundation

@main
struct SelectedTextCleanerSmoke {
    static func main() {
        let cases: [(String, CleanedSelection)] = [
            ("“supercilious,”", .value("supercilious")),
            ("  conscientious\n\tworker  ", .value("conscientious worker")),
            ("mother-in-law's", .value("mother-in-law's")),
            ("incredulous?!", .value("incredulous")),
            (String(repeating: "a", count: 101), .tooLong(101)),
            (" \n\t ", .empty)
        ]

        guard cases.allSatisfy({ SelectedTextCleaner.clean($0.0) == $0.1 }) else {
            exit(1)
        }
        print("SelectedTextCleaner: 6/6 passed")
    }
}

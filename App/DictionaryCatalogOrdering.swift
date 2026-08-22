import Foundation

enum DictionaryCatalogOrderingError: LocalizedError, Equatable, Sendable {
    case dictionaryNotFound
    case crossLevelMove

    var errorDescription: String? {
        switch self {
        case .dictionaryNotFound: return "找不到要调整的词典。"
        case .crossLevelMove: return "当前词典顺序无法调整。"
        }
    }
}

enum DictionaryMoveDirection: Sendable {
    case up
    case down
}

struct DictionaryCatalogOrdering: Sendable {
    static let legacyDefaultOrder = [
        DictionarySourceID.oxfordOALD8.rawValue,
        DictionarySourceID.century21.rawValue,
        DictionarySourceID.newOxford.rawValue,
        DictionarySourceID.medicalEnglishChinese.rawValue,
        DictionarySourceID.affixRootA.rawValue
    ]

    static func canMove(_ dictionaryID: String,
                        direction: DictionaryMoveDirection,
                        in catalog: DictionaryCatalog) -> Bool {
        let group = groupContaining(dictionaryID, in: catalog)
        guard let index = group.firstIndex(where: { $0.dictionaryID == dictionaryID }) else {
            return false
        }
        switch direction {
        case .up: return index > 0
        case .down: return index + 1 < group.count
        }
    }

    static func moving(_ dictionaryID: String,
                       direction: DictionaryMoveDirection,
                       in catalog: DictionaryCatalog,
                       now: Date = Date()) throws -> DictionaryCatalog {
        var group = catalog.activeSortedDictionaries
        guard let index = group.firstIndex(where: { $0.dictionaryID == dictionaryID }) else {
            throw DictionaryCatalogOrderingError.dictionaryNotFound
        }
        let destination: Int
        switch direction {
        case .up:
            guard index > 0 else { return catalog }
            destination = index - 1
        case .down:
            guard index + 1 < group.count else { return catalog }
            destination = index + 1
        }
        group.swapAt(index, destination)
        return applying(group: group, to: catalog, now: now)
    }

    static func moving(_ dictionaryID: String,
                       toDisplayedRow proposedRow: Int,
                       in catalog: DictionaryCatalog,
                       now: Date = Date()) throws -> DictionaryCatalog {
        let displayed = catalog.activeSortedDictionaries
        guard let sourceIndex = displayed.firstIndex(where: {
            $0.dictionaryID == dictionaryID
        }) else {
            throw DictionaryCatalogOrderingError.dictionaryNotFound
        }
        let source = displayed[sourceIndex]
        var remaining = displayed
        remaining.remove(at: sourceIndex)
        var insertion = min(max(proposedRow, 0), displayed.count)
        if insertion > sourceIndex { insertion -= 1 }

        remaining.insert(source, at: insertion)
        return applying(group: remaining, to: catalog, now: now)
    }

    static func restoringDefaults(in catalog: DictionaryCatalog,
                                  now: Date = Date()) -> DictionaryCatalog {
        let ordered = catalog.dictionaries
            .filter { !$0.isRetiredLegacyRegistration }
            .sorted(by: defaultOrder)
        return applying(group: ordered, to: catalog, now: now)
    }

    static func removingAndCompacting(_ dictionaryID: String,
                                      from catalog: DictionaryCatalog,
                                      now: Date = Date()) throws -> DictionaryCatalog {
        guard catalog.dictionaries.contains(where: {
            $0.dictionaryID == dictionaryID
        }) else {
            throw DictionaryCatalogOrderingError.dictionaryNotFound
        }
        var updated = catalog
        updated.dictionaries.removeAll { $0.dictionaryID == dictionaryID }
        let group = updated.activeSortedDictionaries
        updated = applying(group: group, to: updated, now: now)
        if updated != catalog { updated.updatedAt = now }
        return updated
    }

    private static func groupContaining(_ dictionaryID: String,
                                        in catalog: DictionaryCatalog)
        -> [DictionaryDescriptor] {
        guard catalog.dictionaries.contains(where: {
            $0.dictionaryID == dictionaryID
        }) else { return [] }
        return catalog.activeSortedDictionaries
    }

    private static func applying(group: [DictionaryDescriptor],
                                 to catalog: DictionaryCatalog,
                                 now: Date) -> DictionaryCatalog {
        let retired = catalog.dictionaries
            .filter(\.isRetiredLegacyRegistration)
            .sorted {
                if $0.retiredLegacyRegistrationAt != $1.retiredLegacyRegistrationAt {
                    return ($0.retiredLegacyRegistrationAt ?? .distantPast) <
                        ($1.retiredLegacyRegistrationAt ?? .distantPast)
                }
                return $0.dictionaryID < $1.dictionaryID
            }
        let all = group + retired
        var positions = Dictionary(uniqueKeysWithValues: all.enumerated().map {
            ($0.element.dictionaryID, Int64($0.offset + 1))
        })
        var updated = catalog
        var changed = false
        for index in updated.dictionaries.indices {
            guard let position = positions.removeValue(
                forKey: updated.dictionaries[index].dictionaryID
            ), updated.dictionaries[index].sortPosition != position else { continue }
            updated.dictionaries[index].sortPosition = position
            updated.dictionaries[index].updatedAt = now
            changed = true
        }
        if changed { updated.updatedAt = now }
        return updated
    }

    private static func defaultOrder(_ lhs: DictionaryDescriptor,
                                     before rhs: DictionaryDescriptor) -> Bool {
        let lhsLegacy = legacyDefaultOrder.firstIndex(of: lhs.dictionaryID)
        let rhsLegacy = legacyDefaultOrder.firstIndex(of: rhs.dictionaryID)
        switch (lhsLegacy, rhsLegacy) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): break
        }
        let lhsSource = defaultSourceRank(lhs.sourceKind)
        let rhsSource = defaultSourceRank(rhs.sourceKind)
        if lhsSource != rhsSource { return lhsSource < rhsSource }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.dictionaryID < rhs.dictionaryID
    }

    private static func defaultSourceRank(_ source: DictionarySourceKind) -> Int {
        switch source {
        case .legacyReference: return 0
        case .managedLocal, .externalReference: return 1
        case .openResource: return 2
        }
    }
}

@MainActor
final class DictionaryCatalogOrderCoordinator {
    typealias SaveCatalog = (DictionaryCatalog) throws -> Void

    private(set) var catalog: DictionaryCatalog
    private let saveCatalog: SaveCatalog?
    private let catalogStore: DictionaryCatalogStore?

    init(catalog: DictionaryCatalog,
         catalogStore: DictionaryCatalogStore,
         saveCatalog: SaveCatalog? = nil) {
        self.catalog = catalog
        self.catalogStore = saveCatalog == nil ? catalogStore : nil
        self.saveCatalog = saveCatalog
    }

    func synchronize(catalog: DictionaryCatalog) {
        self.catalog = catalog
    }

    @discardableResult
    func save(_ proposed: DictionaryCatalog) throws -> DictionaryCatalog {
        guard proposed != catalog else { return catalog }
        if let catalogStore {
            let requestedPositions = Dictionary(uniqueKeysWithValues: proposed.dictionaries.map {
                ($0.dictionaryID, $0.sortPosition)
            })
            guard Set(requestedPositions.keys) == Set(catalog.dictionaries.map(\.dictionaryID)) else {
                throw DictionaryCatalogOrderingError.dictionaryNotFound
            }
            let mutation = try catalogStore.mutate { latest, _ in
                guard Set(requestedPositions.keys) == Set(latest.dictionaries.map(\.dictionaryID)) else {
                    throw DictionaryCatalogOrderingError.dictionaryNotFound
                }
                for index in latest.dictionaries.indices {
                    guard let position = requestedPositions[latest.dictionaries[index].dictionaryID] else { continue }
                    latest.dictionaries[index].sortPosition = position
                    latest.dictionaries[index].updatedAt = proposed.updatedAt
                }
                latest.updatedAt = proposed.updatedAt
            }
            catalog = mutation.catalog
            return mutation.catalog
        }
        guard let saveCatalog else { throw DictionaryCatalogOrderingError.dictionaryNotFound }
        try saveCatalog(proposed)
        catalog = proposed
        return proposed
    }
}

import Foundation

enum DictionaryCatalogOrderingError: LocalizedError, Equatable, Sendable {
    case dictionaryNotFound
    case crossLevelMove

    var errorDescription: String? {
        switch self {
        case .dictionaryNotFound: return "找不到要调整的词典。"
        case .crossLevelMove: return "只能在相同查询级别内调整顺序。"
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
        var group = groupContaining(dictionaryID, in: catalog)
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
        let displayed = catalog.sortedDictionaries
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

        let matchingIndices = remaining.indices.filter {
            remaining[$0].queryLevel == source.queryLevel
        }
        guard let first = matchingIndices.first, let last = matchingIndices.last else {
            return catalog
        }
        guard insertion >= first, insertion <= last + 1 else {
            throw DictionaryCatalogOrderingError.crossLevelMove
        }
        remaining.insert(source, at: insertion)
        let reorderedGroup = remaining.filter { $0.queryLevel == source.queryLevel }
        return applying(group: reorderedGroup, to: catalog, now: now)
    }

    static func restoringDefaults(in catalog: DictionaryCatalog,
                                  now: Date = Date()) -> DictionaryCatalog {
        var updated = catalog
        for level in DictionaryQueryLevel.allCases {
            let group = catalog.dictionaries.filter { $0.queryLevel == level }.sorted {
                defaultOrder($0, before: $1, level: level)
            }
            updated = applying(group: group, to: updated, now: now)
        }
        return updated
    }

    static func removingAndCompacting(_ dictionaryID: String,
                                      from catalog: DictionaryCatalog,
                                      now: Date = Date()) throws -> DictionaryCatalog {
        guard let removed = catalog.dictionaries.first(where: {
            $0.dictionaryID == dictionaryID
        }) else {
            throw DictionaryCatalogOrderingError.dictionaryNotFound
        }
        var updated = catalog
        updated.dictionaries.removeAll { $0.dictionaryID == dictionaryID }
        let group = updated.sortedDictionaries.filter {
            $0.queryLevel == removed.queryLevel
        }
        updated = applying(group: group, to: updated, now: now)
        if updated != catalog { updated.updatedAt = now }
        return updated
    }

    private static func groupContaining(_ dictionaryID: String,
                                        in catalog: DictionaryCatalog)
        -> [DictionaryDescriptor] {
        guard let level = catalog.dictionaries.first(where: {
            $0.dictionaryID == dictionaryID
        })?.queryLevel else { return [] }
        return catalog.sortedDictionaries.filter { $0.queryLevel == level }
    }

    private static func applying(group: [DictionaryDescriptor],
                                 to catalog: DictionaryCatalog,
                                 now: Date) -> DictionaryCatalog {
        var positions = Dictionary(uniqueKeysWithValues: group.enumerated().map {
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
                                     before rhs: DictionaryDescriptor,
                                     level: DictionaryQueryLevel) -> Bool {
        if level == .preferred {
            let lhsLegacy = legacyDefaultOrder.firstIndex(of: lhs.dictionaryID)
            let rhsLegacy = legacyDefaultOrder.firstIndex(of: rhs.dictionaryID)
            switch (lhsLegacy, rhsLegacy) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.dictionaryID < rhs.dictionaryID
    }
}

@MainActor
final class DictionaryCatalogOrderCoordinator {
    typealias SaveCatalog = (DictionaryCatalog) throws -> Void

    private(set) var catalog: DictionaryCatalog
    private let saveCatalog: SaveCatalog

    init(catalog: DictionaryCatalog,
         catalogStore: DictionaryCatalogStore,
         saveCatalog: SaveCatalog? = nil) {
        self.catalog = catalog
        self.saveCatalog = saveCatalog ?? { try catalogStore.save($0) }
    }

    func synchronize(catalog: DictionaryCatalog) {
        self.catalog = catalog
    }

    @discardableResult
    func save(_ proposed: DictionaryCatalog) throws -> DictionaryCatalog {
        guard proposed != catalog else { return catalog }
        try saveCatalog(proposed)
        catalog = proposed
        return proposed
    }
}

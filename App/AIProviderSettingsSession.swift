import Foundation

enum AIProviderDraftKeyState: Equatable {
    case notConfigured
    case configured
    case pendingReplacement
    case pendingDeletion
}

struct AIConnectionTestGate {
    private(set) var isRunning = false

    mutating func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    mutating func finish() { isRunning = false }
}

struct AIProviderSettingsSession {
    let persistedProfiles: [UUID: AIProviderConfiguration]
    private(set) var editingDrafts: [UUID: AIProviderConfiguration]
    private(set) var orderedProviderIDs: [UUID]
    private(set) var selectedProviderID: UUID?
    private(set) var pendingAPIKeys: [UUID: String] = [:]
    private(set) var configuredProviderIDs: Set<UUID>
    private(set) var keyDeletionIDs: Set<UUID> = []
    var automaticFallbackEnabled: Bool
    var automaticSentenceAnalysisEnabled: Bool

    init(snapshot: AIProviderCatalogSnapshot) {
        let ordered = snapshot.catalog.profiles.sorted { $0.priority < $1.priority }
        persistedProfiles = Dictionary(uniqueKeysWithValues: ordered.map { ($0.providerID, $0) })
        editingDrafts = persistedProfiles
        orderedProviderIDs = ordered.map(\.providerID)
        selectedProviderID = orderedProviderIDs.first
        configuredProviderIDs = snapshot.configuredProviderIDs
        automaticFallbackEnabled = snapshot.catalog.automaticFallbackEnabled
        automaticSentenceAnalysisEnabled = snapshot.catalog.automaticSentenceAnalysisEnabled
    }

    var selectedDraft: AIProviderConfiguration? {
        guard let selectedProviderID else { return nil }
        return editingDrafts[selectedProviderID]
    }

    var profilesInPriorityOrder: [AIProviderConfiguration] {
        orderedProviderIDs.compactMap { editingDrafts[$0] }
    }

    mutating func select(_ providerID: UUID) -> Bool {
        guard editingDrafts[providerID] != nil else { return false }
        selectedProviderID = providerID
        return true
    }

    mutating func updateDraft(_ profile: AIProviderConfiguration) {
        guard profile.providerID == selectedProviderID,
              editingDrafts[profile.providerID] != nil else { return }
        editingDrafts[profile.providerID] = profile
    }

    mutating func setPendingAPIKey(_ rawValue: String, for providerID: UUID) {
        guard editingDrafts[providerID] != nil else { return }
        let clean = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            pendingAPIKeys.removeValue(forKey: providerID)
        } else {
            pendingAPIKeys[providerID] = clean
            keyDeletionIDs.remove(providerID)
        }
    }

    func pendingAPIKey(for providerID: UUID) -> String {
        pendingAPIKeys[providerID] ?? ""
    }

    func keyState(for providerID: UUID) -> AIProviderDraftKeyState {
        if keyDeletionIDs.contains(providerID) { return .pendingDeletion }
        if pendingAPIKeys[providerID]?.isEmpty == false { return .pendingReplacement }
        return configuredProviderIDs.contains(providerID) ? .configured : .notConfigured
    }

    mutating func markKeyForDeletion(_ providerID: UUID) {
        guard editingDrafts[providerID] != nil else { return }
        pendingAPIKeys.removeValue(forKey: providerID)
        keyDeletionIDs.insert(providerID)
    }

    mutating func add(_ template: AIProviderConfiguration) -> UUID {
        var profile = template
        profile.providerID = UUID()
        profile.priority = orderedProviderIDs.count + 1
        profile.enabled = false
        editingDrafts[profile.providerID] = profile
        orderedProviderIDs.append(profile.providerID)
        selectedProviderID = profile.providerID
        return profile.providerID
    }

    @discardableResult
    mutating func remove(_ providerID: UUID, deleteKey: Bool) -> Bool {
        guard orderedProviderIDs.count > 1,
              providerID != AIProviderConfiguration.deepSeekProviderID,
              editingDrafts.removeValue(forKey: providerID) != nil else { return false }
        orderedProviderIDs.removeAll { $0 == providerID }
        pendingAPIKeys.removeValue(forKey: providerID)
        if deleteKey, configuredProviderIDs.contains(providerID) {
            keyDeletionIDs.insert(providerID)
        }
        if selectedProviderID == providerID { selectedProviderID = orderedProviderIDs.first }
        renumberPriorities()
        return true
    }

    mutating func setAsPrimary(_ providerID: UUID) {
        guard let index = orderedProviderIDs.firstIndex(of: providerID), index != 0 else { return }
        orderedProviderIDs.remove(at: index)
        orderedProviderIDs.insert(providerID, at: 0)
        renumberPriorities()
    }

    mutating func setAsBackup(_ providerID: UUID) {
        guard orderedProviderIDs.count > 1,
              let index = orderedProviderIDs.firstIndex(of: providerID) else { return }
        if index == 0 {
            orderedProviderIDs.swapAt(0, 1)
        } else if index != 1 {
            orderedProviderIDs.remove(at: index)
            orderedProviderIDs.insert(providerID, at: 1)
        }
        renumberPriorities()
    }

    func isPrimary(_ providerID: UUID) -> Bool { orderedProviderIDs.first == providerID }

    func catalogForSaving() throws -> AIProviderCatalog {
        let profiles = profilesInPriorityOrder
        return try AIProviderCatalog(
            profiles: profiles,
            automaticFallbackEnabled: automaticFallbackEnabled,
            automaticSentenceAnalysisEnabled: false
        ).normalizedForSave()
    }

    var nonemptyReplacementKeys: [UUID: String] {
        pendingAPIKeys.filter { !$0.value.isEmpty && editingDrafts[$0.key] != nil }
    }

    private mutating func renumberPriorities() {
        for (index, id) in orderedProviderIDs.enumerated() {
            editingDrafts[id]?.priority = index + 1
        }
    }
}

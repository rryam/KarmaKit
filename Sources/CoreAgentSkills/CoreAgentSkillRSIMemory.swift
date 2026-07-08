import Foundation

public enum CoreAgentSkillRSIMemorySource: String, Codable, Equatable, Sendable {
  case rqgm
  case autoMem
  case custom
}

public struct CoreAgentSkillRSIMemoryReference: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let source: CoreAgentSkillRSIMemorySource
  public let contentDigest: String
  public let metadata: [String: String]

  public init(
    id: String,
    source: CoreAgentSkillRSIMemorySource,
    contentDigest: String,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.source = source
    self.contentDigest = contentDigest
    self.metadata = metadata
  }
}

public struct CoreAgentSkillRSIMemoryFetchRequest: Sendable {
  public let runID: String
  public let skillID: CoreAgentSkillID
  public let evidenceDigestKeys: [String]
  public let maxEntries: Int

  public init(
    runID: String,
    skillID: CoreAgentSkillID,
    evidenceDigestKeys: [String],
    maxEntries: Int
  ) {
    self.runID = runID
    self.skillID = skillID
    self.evidenceDigestKeys = evidenceDigestKeys
    self.maxEntries = max(1, maxEntries)
  }
}

public protocol CoreAgentSkillRSIMemoryAdapter: Sendable {
  func fetchReferences(
    _ request: CoreAgentSkillRSIMemoryFetchRequest
  ) async throws -> [CoreAgentSkillRSIMemoryReference]
}

public struct CoreAgentSkillRSIMemoryImportConfig: Sendable {
  public let adapter: any CoreAgentSkillRSIMemoryAdapter
  public let skillID: CoreAgentSkillID
  public let maxEntries: Int

  public init(
    adapter: any CoreAgentSkillRSIMemoryAdapter,
    skillID: CoreAgentSkillID,
    maxEntries: Int = 32
  ) {
    self.adapter = adapter
    self.skillID = skillID
    self.maxEntries = max(1, maxEntries)
  }
}

public struct CoreAgentSkillRSIMemoryImportReport: Equatable, Sendable {
  public let runID: String
  public let skillID: CoreAgentSkillID
  public let importedEntryIDs: [String]
  public let skippedDuplicateEntryIDs: [String]

  public init(
    runID: String,
    skillID: CoreAgentSkillID,
    importedEntryIDs: [String],
    skippedDuplicateEntryIDs: [String]
  ) {
    self.runID = runID
    self.skillID = skillID
    self.importedEntryIDs = importedEntryIDs
    self.skippedDuplicateEntryIDs = skippedDuplicateEntryIDs
  }
}

public struct CoreAgentSkillRSIMemoryImporter: Sendable {
  private let store: any CoreAgentSkillStore

  public init(store: any CoreAgentSkillStore) {
    self.store = store
  }

  public func importReferences(
    _ references: [CoreAgentSkillRSIMemoryReference],
    runID: String,
    skillID: CoreAgentSkillID
  ) async throws -> CoreAgentSkillRSIMemoryImportReport {
    guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "RSI memory import run ID must be non-empty"
      )
    }
    var importedEntryIDs: [String] = []
    var skippedDuplicateEntryIDs: [String] = []
    var seenEntryIDs: Set<String> = []
    let existingMemory = await store.optimizerMemory(skillID: skillID)
    var existingImportedIDs = Set(
      existingMemory.metaObservations.compactMap { observation -> String? in
        guard observation.reason == .externalMemoryImport else { return nil }
        return Self.entryID(from: observation.notes)
      }
    )

    for reference in references {
      try Self.validateReference(reference)
      guard seenEntryIDs.insert(reference.id).inserted else {
        skippedDuplicateEntryIDs.append(reference.id)
        continue
      }
      guard existingImportedIDs.insert(reference.id).inserted else {
        skippedDuplicateEntryIDs.append(reference.id)
        continue
      }
      try await store.recordMetaObservation(
        CoreAgentSkillMetaObservation(
          runID: runID,
          proposalID: "rsi-memory-\(reference.id)",
          reason: .externalMemoryImport,
          notes: Self.sanitizedNotes(for: reference)
        ),
        skillID: skillID
      )
      importedEntryIDs.append(reference.id)
    }

    return CoreAgentSkillRSIMemoryImportReport(
      runID: runID,
      skillID: skillID,
      importedEntryIDs: importedEntryIDs,
      skippedDuplicateEntryIDs: skippedDuplicateEntryIDs
    )
  }

  private static func validateReference(
    _ reference: CoreAgentSkillRSIMemoryReference
  ) throws {
    guard isSafeProposalIdentifier(reference.id) else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "RSI memory entry ID is invalid"
      )
    }
    guard isSHA256Digest(reference.contentDigest) else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "RSI memory content digest must be lowercase sha256"
      )
    }
    for key in reference.metadata.keys {
      guard rsiMemoryMetadataAllowlist.contains(key) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "RSI memory metadata key is not allowlisted"
        )
      }
    }
    for value in reference.metadata.values {
      guard !value.isEmpty, value.count <= 256 else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "RSI memory metadata value is invalid"
        )
      }
    }
  }

  private static func sanitizedNotes(
    for reference: CoreAgentSkillRSIMemoryReference
  ) -> String {
    let metadata = reference.metadata.keys.sorted().map { key in
      "\(key)=\(reference.metadata[key] ?? "")"
    }.joined(separator: " ")
    if metadata.isEmpty {
      return
        "source=\(reference.source.rawValue) entry_id=\(reference.id) content_digest=\(reference.contentDigest)"
    }
    return
      "source=\(reference.source.rawValue) entry_id=\(reference.id) content_digest=\(reference.contentDigest) \(metadata)"
  }

  private static func entryID(from notes: String) -> String? {
    for token in notes.split(separator: " ") {
      guard token.hasPrefix("entry_id=") else { continue }
      let value = token.dropFirst("entry_id=".count)
      return value.isEmpty ? nil : String(value)
    }
    return nil
  }
}

private let rsiMemoryMetadataAllowlist: Set<String> = [
  "graph_digest",
  "memory_kind",
  "relation_digest",
  "source_suite_id",
]

private func isSHA256Digest(_ value: String) -> Bool {
  guard value.hasPrefix("sha256:") else { return false }
  let hex = value.dropFirst("sha256:".count)
  guard hex.count == 64 else { return false }
  return hex.unicodeScalars.allSatisfy { scalar in
    (48...57).contains(Int(scalar.value)) || (97...102).contains(Int(scalar.value))
  }
}

private func isSafeProposalIdentifier(_ value: String) -> Bool {
  let scalars = Array(value.unicodeScalars)
  guard !scalars.isEmpty, scalars.count <= 128 else { return false }
  guard isASCIIIdentifierHead(scalars[0]) else { return false }
  return scalars.allSatisfy { scalar in
    let value = Int(scalar.value)
    return isASCIIIdentifierHead(scalar) || (48...57).contains(value)
      || value == 45 || value == 46 || value == 58 || value == 95
  }
}

private func isASCIIIdentifierHead(_ scalar: Unicode.Scalar) -> Bool {
  (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
}

import CoreAgent
import Foundation
import FoundationModels

actor CoreAgentMemoryRuntime {
  let scope: CoreAgentMemoryScope
  let hasIndex: Bool

  private let store: any CoreAgentMemoryStore
  private let index: (any CoreAgentMemoryIndex)?
  private let disclosurePolicy: CoreAgentMemoryDisclosurePolicy
  private let retrievalConfiguration: CoreAgentMemoryRetrievalConfiguration
  private let observers: [any CoreAgentMemoryObserver]
  private var indexRepairTasks: [UUID: Task<Void, Never>] = [:]

  init(
    scope: CoreAgentMemoryScope,
    store: any CoreAgentMemoryStore,
    index: (any CoreAgentMemoryIndex)?,
    disclosurePolicy: CoreAgentMemoryDisclosurePolicy,
    retrievalConfiguration: CoreAgentMemoryRetrievalConfiguration,
    observers: [any CoreAgentMemoryObserver]
  ) {
    self.scope = scope
    self.store = store
    self.index = index
    self.hasIndex = index != nil
    self.disclosurePolicy = disclosurePolicy
    self.retrievalConfiguration = retrievalConfiguration
    self.observers = observers
  }

  func persist(_ record: CoreAgentMemoryRecord) async throws -> CoreAgentMemoryRecord {
    try await store.save(record)
    return await indexAfterCanonicalWrite(record)
  }

  func approve(_ candidateID: UUID) async throws -> CoreAgentMemoryRecord {
    guard let candidate = try await store.candidate(id: candidateID, in: scope) else {
      throw CoreAgentMemoryError.candidateNotFound(candidateID)
    }
    guard candidate.status == .pending else {
      throw CoreAgentMemoryError.invalidCandidateDecision
    }
    guard let episode = try await store.record(id: candidate.sourceRecordID, in: scope) else {
      throw CoreAgentMemoryError.recordNotFound(candidate.sourceRecordID)
    }
    guard episode.isActive else {
      throw CoreAgentMemoryError.sourceRecordInactive(episode.id)
    }
    let draft = candidate.draft
    let record = try CoreAgentMemoryRecord(
      scope: scope,
      kind: draft.kind,
      content: draft.content,
      source: CoreAgentMemorySource(
        kind: .conversation,
        runID: episode.source.runID,
        transcriptEntryIDs: episode.source.transcriptEntryIDs,
        assetReferences: episode.source.assetReferences,
        metadata: ["candidate_id": candidate.id.uuidString.lowercased()]
      ),
      observedAt: episode.observedAt,
      validFrom: draft.validFrom,
      validUntil: draft.validUntil,
      authority: draft.authority,
      confidence: draft.confidence,
      importance: draft.importance,
      sensitivity: draft.sensitivity,
      indexState: hasIndex ? .pending : .notConfigured
    )
    try await store.approveCandidate(id: candidateID, as: record, in: scope)
    let indexed = await indexAfterCanonicalWrite(record)
    await emit(
      .init(
        kind: .candidateApproved,
        scope: scope,
        recordID: indexed.id,
        candidateID: candidateID
      )
    )
    return indexed
  }

  func reject(_ candidateID: UUID, reason: String?) async throws {
    try await store.rejectCandidate(id: candidateID, in: scope, reason: reason)
    await emit(.init(kind: .candidateRejected, scope: scope, candidateID: candidateID))
  }

  func indexAfterCanonicalWrite(
    _ record: CoreAgentMemoryRecord
  ) async -> CoreAgentMemoryRecord {
    guard let index else { return record }
    var updated = record
    do {
      try await index.upsert(record)
      updated.indexState = .indexed
      updated.updatedAt = Date()
      try await store.save(updated)
      await emit(.init(kind: .indexingRepaired, scope: scope, recordID: record.id))
    } catch {
      updated.indexState = .pending
      updated.updatedAt = Date()
      try? await store.save(updated)
      await emit(
        .init(
          kind: .indexingFailed,
          scope: scope,
          recordID: record.id,
          attributes: ["error_type": String(reflecting: Swift.type(of: error))]
        )
      )
      scheduleIndexRepair(recordID: record.id)
    }
    return updated
  }

  func search(
    query: String,
    maximumResults: Int? = nil
  ) async throws -> [CoreAgentMemorySearchResult] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    let maximum = min(
      max(1, maximumResults ?? retrievalConfiguration.maximumRecords),
      retrievalConfiguration.maximumRecords
    )
    let overfetch = maximum * retrievalConfiguration.overfetchMultiplier
    await emit(
      .init(
        kind: .retrievalStarted,
        scope: scope,
        attributes: ["maximum_results": String(maximum)]
      )
    )

    var relevance: [UUID: Double] = [:]
    let lexical = try await store.lexicalSearch(query: query, in: scope, limit: overfetch)
    merge(lexical, into: &relevance)
    if let index {
      do {
        let indexed = try await index.search(query: query, in: scope, limit: overfetch)
        merge(indexed, into: &relevance)
      } catch {
        await emit(
          .init(
            kind: .indexingFailed,
            scope: scope,
            attributes: [
              "operation": "search",
              "error_type": String(reflecting: Swift.type(of: error)),
            ]
          )
        )
      }
    }

    let orderedIDs = relevance.keys.sorted {
      let left = relevance[$0, default: 0]
      let right = relevance[$1, default: 0]
      if left != right { return left > right }
      return $0.uuidString < $1.uuidString
    }
    let now = Date()
    let canonical = try await store.records(ids: orderedIDs, in: scope)
    let filtered = canonical.filter {
      $0.status == .active
        && $0.isValid(at: now)
        && disclosurePolicy.allows($0.sensitivity)
    }
    let results = filtered.map {
      CoreAgentMemorySearchResult(record: $0, relevance: relevance[$0.id, default: 0])
    }.sorted(by: Self.resultsBefore).prefix(maximum).map { $0 }

    await emit(
      .init(
        kind: .retrievalFiltered,
        scope: scope,
        attributes: [
          "candidate_count": String(orderedIDs.count),
          "filtered_count": String(orderedIDs.count - filtered.count),
        ]
      )
    )
    await emit(
      .init(
        kind: .retrievalCompleted,
        scope: scope,
        attributes: ["record_count": String(results.count)]
      )
    )
    return results
  }

  func format(_ results: [CoreAgentMemorySearchResult]) -> String {
    CoreAgentMemoryContextFormatter.format(
      results,
      maximumCharacters: retrievalConfiguration.maximumCharacters
    )
  }

  func removeDerivative(id: UUID) async {
    indexRepairTasks.removeValue(forKey: id)?.cancel()
    guard let index else { return }
    do {
      try await index.remove(id: id, in: scope)
    } catch {
      await emit(
        .init(
          kind: .indexingFailed,
          scope: scope,
          recordID: id,
          attributes: [
            "operation": "remove",
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
      )
    }
  }

  func removeAllDerivatives() async {
    for task in indexRepairTasks.values { task.cancel() }
    indexRepairTasks.removeAll()
    guard let index else { return }
    do {
      try await index.removeAll(in: scope)
    } catch {
      await emit(
        .init(
          kind: .indexingFailed,
          scope: scope,
          attributes: [
            "operation": "remove_all",
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
      )
    }
  }

  func rebuildIndex() async throws {
    guard let index else { return }
    for task in indexRepairTasks.values { task.cancel() }
    indexRepairTasks.removeAll()
    try await index.removeAll(in: scope)
    let now = Date()
    for record in try await store.records(in: scope)
    where record.status == .active && record.isValid(at: now) {
      do {
        try await index.upsert(record)
        try await store.updateIndexState(.indexed, for: record.id, in: scope)
        await emit(.init(kind: .indexingRepaired, scope: scope, recordID: record.id))
      } catch {
        try? await store.updateIndexState(.failed, for: record.id, in: scope)
        await emit(
          .init(
            kind: .indexingFailed,
            scope: scope,
            recordID: record.id,
            attributes: ["error_type": String(reflecting: Swift.type(of: error))]
          )
        )
      }
    }
  }

  func emit(_ event: CoreAgentMemoryEvent) async {
    for observer in observers {
      await observer.memoryDidEmit(event)
    }
  }

  func flushIndexRepairs() async {
    while !indexRepairTasks.isEmpty {
      let tasks = Array(indexRepairTasks.values)
      for task in tasks { await task.value }
    }
  }

  private func scheduleIndexRepair(recordID: UUID) {
    guard index != nil, indexRepairTasks[recordID] == nil else { return }
    indexRepairTasks[recordID] = Task { [weak self] in
      guard let self else { return }
      for attempt in 1...3 {
        if attempt > 1 {
          try? await Task.sleep(for: .milliseconds(250 * attempt))
        }
        guard !Task.isCancelled else { break }
        if await self.repairIndex(recordID: recordID, attempt: attempt) { break }
      }
      await self.finishIndexRepair(recordID: recordID)
    }
  }

  private func repairIndex(recordID: UUID, attempt: Int) async -> Bool {
    guard let index else { return true }
    do {
      guard let record = try await store.record(id: recordID, in: scope),
        record.status == .active,
        record.isValid(at: Date())
      else {
        return true
      }
      try await index.upsert(record)
      if Task.isCancelled {
        try? await index.remove(id: recordID, in: scope)
        return true
      }
      try await store.updateIndexState(.indexed, for: recordID, in: scope)
      await emit(
        .init(
          kind: .indexingRepaired,
          scope: scope,
          recordID: recordID,
          attributes: ["attempt": String(attempt)]
        )
      )
      return true
    } catch {
      if attempt == 3 {
        try? await store.updateIndexState(.failed, for: recordID, in: scope)
      }
      await emit(
        .init(
          kind: .indexingFailed,
          scope: scope,
          recordID: recordID,
          attributes: [
            "attempt": String(attempt),
            "terminal": String(attempt == 3),
            "error_type": String(reflecting: Swift.type(of: error)),
          ]
        )
      )
      return false
    }
  }

  private func finishIndexRepair(recordID: UUID) {
    indexRepairTasks.removeValue(forKey: recordID)
  }

  private func merge(
    _ candidates: [CoreAgentMemorySearchCandidate],
    into relevance: inout [UUID: Double]
  ) {
    for (index, candidate) in candidates.enumerated() {
      let reciprocalRank = 1 / Double(index + 1)
      relevance[candidate.id] = max(relevance[candidate.id, default: 0], reciprocalRank)
    }
  }

  private static func resultsBefore(
    _ lhs: CoreAgentMemorySearchResult,
    _ rhs: CoreAgentMemorySearchResult
  ) -> Bool {
    if lhs.relevance != rhs.relevance { return lhs.relevance > rhs.relevance }
    if lhs.record.authority.rank != rhs.record.authority.rank {
      return lhs.record.authority.rank > rhs.record.authority.rank
    }
    if lhs.record.observedAt != rhs.record.observedAt {
      return lhs.record.observedAt > rhs.record.observedAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}

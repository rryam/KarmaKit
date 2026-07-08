import CoreAgent
import Foundation
import FoundationModels

public actor CoreAgentMemoryCoordinator: CoreAgentSessionPlugin {
  public nonisolated let identifier = "coreagent.memory"
  public nonisolated let scope: CoreAgentMemoryScope
  public nonisolated let searchTool: CoreAgentMemorySearchTool
  public nonisolated let failurePolicies: CoreAgentPluginFailurePolicies

  public nonisolated var tools: [any Tool] { [searchTool] }

  private let store: any CoreAgentMemoryStore
  private let runtime: CoreAgentMemoryRuntime
  private let consolidator: (any CoreAgentMemoryConsolidator)?
  private let consolidationWorker: CoreAgentMemoryConsolidationWorker?
  private var consolidationGeneration: UInt64 = 0
  private var pendingEpisodeCaptures = 0
  private var episodeCaptureWaiters: [CheckedContinuation<Void, Never>] = []

  public init(
    scope: CoreAgentMemoryScope,
    store: any CoreAgentMemoryStore,
    disclosurePolicy: CoreAgentMemoryDisclosurePolicy,
    index: (any CoreAgentMemoryIndex)? = nil,
    consolidator: (any CoreAgentMemoryConsolidator)? = nil,
    approvalProvider: any CoreAgentMemoryApprovalProvider =
      DeferCoreAgentMemoryApprovalProvider(),
    retrievalConfiguration: CoreAgentMemoryRetrievalConfiguration = .default,
    failurePolicies: CoreAgentPluginFailurePolicies = .default,
    observers: [any CoreAgentMemoryObserver] = []
  ) {
    let runtime = CoreAgentMemoryRuntime(
      scope: scope,
      store: store,
      index: index,
      disclosurePolicy: disclosurePolicy,
      retrievalConfiguration: retrievalConfiguration,
      observers: observers
    )
    self.scope = scope
    self.store = store
    self.runtime = runtime
    self.searchTool = CoreAgentMemorySearchTool(runtime: runtime)
    self.consolidator = consolidator
    self.failurePolicies = failurePolicies
    if let consolidator {
      let worker = CoreAgentMemoryConsolidationWorker(
        scope: scope,
        store: store,
        consolidator: consolidator,
        approvalProvider: approvalProvider,
        runtime: runtime
      )
      self.consolidationWorker = worker
      Task { await worker.resume() }
    } else {
      self.consolidationWorker = nil
    }
  }

  public func prepare(for request: CoreAgentPluginRequest) async throws
    -> CoreAgentPluginPreparation
  {
    guard request.mode == .explicitModel,
      let query = request.contextQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
      !query.isEmpty
    else {
      return .empty
    }

    let results = try await runtime.search(query: query)
    guard !results.isEmpty else { return .empty }
    let context = await runtime.format(results)
    await runtime.emit(
      .init(
        kind: .contextInjected,
        scope: scope,
        attributes: ["record_count": String(results.count)]
      )
    )
    return CoreAgentPluginPreparation(
      contextBlocks: [
        CoreAgentContextBlock(
          id: CoreAgentMemoryContextFormatter.blockID(for: results),
          content: context,
          attributes: ["record_count": String(results.count)]
        )
      ],
      events: results.map {
        CoreAgentPluginEvent(
          name: "memory_retrieved",
          message: "CoreAgent memory record was selected for context.",
          attributes: ["record_id": $0.id.uuidString.lowercased()]
        )
      }
    )
  }

  public func didComplete(_ completion: CoreAgentPluginCompletion) async throws
    -> [CoreAgentPluginEvent]
  {
    guard let capture = Self.captureEpisode(from: completion) else { return [] }
    beginEpisodeCapture()
    defer { finishEpisodeCapture() }
    var episode = try CoreAgentMemoryRecord(
      scope: scope,
      kind: .episode,
      content: capture.content,
      source: CoreAgentMemorySource(
        kind: .conversation,
        runID: completion.runID,
        transcriptEntryIDs: capture.transcriptEntryIDs,
        assetReferences: capture.assetReferences,
        metadata: ["session_mode": completion.mode.rawValue]
      ),
      observedAt: Date(),
      authority: .assistantInference,
      confidence: 1,
      importance: 0.5,
      sensitivity: .personal,
      status: .active,
      retention: .persistent,
      indexState: runtime.hasIndex ? .pending : .notConfigured
    )
    let job = consolidator.map {
      _ in CoreAgentMemoryConsolidationJob(scope: scope, episodeID: episode.id)
    }
    try await store.saveEpisode(episode, enqueueing: job)
    episode = await runtime.indexAfterCanonicalWrite(episode)
    await runtime.emit(
      .init(kind: .episodePersisted, scope: scope, recordID: episode.id)
    )
    await consolidationWorker?.resume()
    return [
      CoreAgentPluginEvent(
        name: "memory_episode_persisted",
        message: "CoreAgent persisted the completed run as an episode.",
        attributes: ["record_id": episode.id.uuidString.lowercased()]
      )
    ]
  }

  public func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent] {
    []
  }

  @discardableResult
  public func remember(
    _ content: String,
    kind: CoreAgentMemoryKind = .fact,
    source: CoreAgentMemorySource = .init(kind: .application),
    authority: CoreAgentMemoryAuthority = .trustedApplication,
    confidence: Double = 1,
    importance: Double = 0.5,
    sensitivity: CoreAgentMemorySensitivity = .personal,
    validFrom: Date? = nil,
    validUntil: Date? = nil,
    retention: CoreAgentMemoryRetention = .persistent
  ) async throws -> CoreAgentMemoryRecord {
    let record = try CoreAgentMemoryRecord(
      scope: scope,
      kind: kind,
      content: content,
      source: source,
      validFrom: validFrom,
      validUntil: validUntil,
      authority: authority,
      confidence: confidence,
      importance: importance,
      sensitivity: sensitivity,
      retention: retention,
      indexState: runtime.hasIndex ? .pending : .notConfigured
    )
    return try await runtime.persist(record)
  }

  @discardableResult
  public func correct(
    recordIDs: [UUID],
    with content: String,
    kind: CoreAgentMemoryKind = .fact,
    source: CoreAgentMemorySource = .init(kind: .correction),
    confidence: Double = 1,
    importance: Double = 1,
    sensitivity: CoreAgentMemorySensitivity = .personal,
    validFrom: Date? = nil,
    validUntil: Date? = nil,
    retention: CoreAgentMemoryRetention = .persistent
  ) async throws -> CoreAgentMemoryRecord {
    let correction = try CoreAgentMemoryRecord(
      scope: scope,
      kind: kind,
      content: content,
      source: source,
      validFrom: validFrom,
      validUntil: validUntil,
      authority: .explicitUserCorrection,
      confidence: confidence,
      importance: importance,
      sensitivity: sensitivity,
      retention: retention,
      supersedes: recordIDs,
      indexState: runtime.hasIndex ? .pending : .notConfigured
    )
    try await store.applyCorrection(correction, superseding: recordIDs)
    for id in recordIDs {
      await runtime.removeDerivative(id: id)
      await runtime.emit(
        .init(
          kind: .recordSuperseded,
          scope: scope,
          recordID: id,
          attributes: ["superseded_by": correction.id.uuidString.lowercased()]
        )
      )
    }
    return await runtime.indexAfterCanonicalWrite(correction)
  }

  @discardableResult
  public func approve(_ candidateID: UUID) async throws -> CoreAgentMemoryRecord {
    try await runtime.approve(candidateID)
  }

  public func reject(_ candidateID: UUID, reason: String? = nil) async throws {
    try await runtime.reject(candidateID, reason: reason)
  }

  public func search(
    _ query: String,
    maximumResults: Int? = nil
  ) async throws -> [CoreAgentMemorySearchResult] {
    try await runtime.search(query: query, maximumResults: maximumResults)
  }

  public func pendingCandidates() async throws -> [CoreAgentMemoryCandidate] {
    try await store.candidates(in: scope, status: .pending)
  }

  public func consolidationFailures() async throws -> [CoreAgentMemoryConsolidationJob] {
    try await store.consolidationJobs(in: scope, statuses: [.failed])
  }

  public func retryFailedConsolidation() async throws {
    consolidationGeneration &+= 1
    try await consolidationWorker?.retryFailed()
  }

  public func resumeConsolidation() async {
    await consolidationWorker?.resume()
  }

  public func flush() async {
    while true {
      let generation = consolidationGeneration
      await waitForEpisodeCaptures()
      await consolidationWorker?.flush()
      await runtime.flushIndexRepairs()
      guard pendingEpisodeCaptures == 0, consolidationGeneration == generation else {
        continue
      }
      return
    }
  }

  public func forget(_ id: UUID, reason: String? = nil) async throws {
    let exportDirectories = try await store.exportDirectories(in: scope)
    _ = try await store.tombstone(id: id, in: scope, reason: reason)
    await runtime.emit(.init(kind: .recordTombstoned, scope: scope, recordID: id))
    await runtime.removeDerivative(id: id)
    for path in exportDirectories {
      try CoreAgentMemoryMarkdownExporter.remove(
        recordID: id,
        scope: scope,
        from: URL(fileURLWithPath: path)
      )
    }
  }

  public func purge(_ id: UUID) async throws {
    let exportDirectories = try await store.exportDirectories(in: scope)
    if try await store.record(id: id, in: scope) != nil {
      _ = try await store.tombstone(id: id, in: scope, reason: "hard_purge")
    }
    await runtime.removeDerivative(id: id)
    try await store.purge(id: id, in: scope)
    for path in exportDirectories {
      try CoreAgentMemoryMarkdownExporter.remove(
        recordID: id,
        scope: scope,
        from: URL(fileURLWithPath: path)
      )
    }
    await runtime.emit(.init(kind: .recordPurged, scope: scope, recordID: id))
  }

  public func purge() async throws {
    let exportDirectories = try await store.exportDirectories(in: scope)
    for record in try await store.records(in: scope) where record.status != .tombstoned {
      _ = try await store.tombstone(id: record.id, in: scope, reason: "scope_purge")
    }
    await runtime.removeAllDerivatives()
    for path in exportDirectories {
      try CoreAgentMemoryMarkdownExporter.removeAll(
        scope: scope,
        from: URL(fileURLWithPath: path)
      )
    }
    try await store.purge(scope: scope)
    await runtime.emit(.init(kind: .scopePurged, scope: scope))
  }

  public func rebuildIndexes() async throws {
    try await runtime.rebuildIndex()
  }

  @discardableResult
  public func exportMarkdown(
    to directory: URL,
    exportedAt: Date = Date(),
    configuration: CoreAgentMemoryMarkdownExportConfiguration = .default
  ) async throws -> CoreAgentMemoryMarkdownManifest {
    let directory = directory.standardizedFileURL
    try await store.registerExportDirectory(directory.path, in: scope)
    return try CoreAgentMemoryMarkdownExporter.export(
      records: try await store.records(in: scope),
      scope: scope,
      to: directory,
      exportedAt: exportedAt,
      configuration: configuration
    )
  }

  private func beginEpisodeCapture() {
    consolidationGeneration &+= 1
    pendingEpisodeCaptures += 1
  }

  private func finishEpisodeCapture() {
    pendingEpisodeCaptures -= 1
    guard pendingEpisodeCaptures == 0 else { return }
    let waiters = episodeCaptureWaiters
    episodeCaptureWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func waitForEpisodeCaptures() async {
    guard pendingEpisodeCaptures > 0 else { return }
    await withCheckedContinuation { continuation in
      episodeCaptureWaiters.append(continuation)
    }
  }

  private static func captureEpisode(
    from completion: CoreAgentPluginCompletion
  ) -> EpisodeCapture? {
    var lines: [String] = []
    var entryIDs: [String] = []
    var assets: [String] = []
    var capturedResponse = false

    for entry in completion.transcriptEntries {
      switch entry {
      case .instructions, .reasoning:
        continue
      case .prompt(let prompt):
        entryIDs.append(prompt.id)
        let rendered = render(prompt.segments, assetReferences: &assets)
        if !rendered.isEmpty { lines.append("USER:\n\(rendered)") }
      case .toolCalls(let calls):
        let visibleCalls = calls.filter { $0.toolName != "coreagent_search_memory" }
        guard !visibleCalls.isEmpty else { continue }
        entryIDs.append(calls.id)
        for call in visibleCalls {
          lines.append("TOOL_CALL \(call.toolName):\n\(call.arguments.jsonString)")
        }
      case .toolOutput(let output):
        guard output.toolName != "coreagent_search_memory" else { continue }
        entryIDs.append(output.id)
        let rendered = render(output.segments, assetReferences: &assets)
        if !rendered.isEmpty {
          lines.append("TOOL_OUTPUT \(output.toolName):\n\(rendered)")
        }
      case .response(let response):
        entryIDs.append(response.id)
        let rendered = render(response.segments, assetReferences: &assets)
        if !rendered.isEmpty {
          lines.append("ASSISTANT:\n\(rendered)")
          capturedResponse = true
        }
      @unknown default:
        continue
      }
    }

    if !capturedResponse {
      let fallback: String
      if case .string(let value) = completion.rawContent.kind {
        fallback = value
      } else {
        fallback = completion.rawContent.jsonString
      }
      if !fallback.isEmpty { lines.append("ASSISTANT:\n\(fallback)") }
    }

    let content = lines.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else { return nil }
    return EpisodeCapture(
      content: content,
      transcriptEntryIDs: entryIDs,
      assetReferences: Array(Set(assets)).sorted()
    )
  }

  private static func render(
    _ segments: [Transcript.Segment],
    assetReferences: inout [String]
  ) -> String {
    segments.compactMap { segment -> String? in
      switch segment {
      case .text(let text):
        return text.content
      case .structure(let structure):
        return structure.content.jsonString
      case .attachment(let attachment):
        let reference: String
        switch attachment.content {
        case .image(let image):
          reference = image.url?.absoluteString ?? "attachment:\(attachment.id)"
        @unknown default:
          reference = "attachment:\(attachment.id)"
        }
        assetReferences.append(reference)
        return "[asset id=\(attachment.id) reference=\(reference)]"
      case .custom(let custom):
        return "[custom segment id=\(custom.id)]"
      @unknown default:
        return nil
      }
    }.joined(separator: "\n")
  }
}

private struct EpisodeCapture: Sendable {
  let content: String
  let transcriptEntryIDs: [String]
  let assetReferences: [String]
}

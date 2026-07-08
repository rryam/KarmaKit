import CoreAgent
import CoreAgentEngine
import CryptoKit
import Darwin
import Foundation
import FoundationModels

public struct CoreAgentSkillID:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral
{
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }
}

public struct CoreAgentSkill: Codable, Equatable, Sendable, Identifiable {
  public let id: CoreAgentSkillID
  public let version: Int
  public let title: String
  public let body: String
  public let tags: [String]
  public let priority: Int
  public let provenance: [CoreAgentSkillProvenance]

  public init(
    id: CoreAgentSkillID,
    version: Int,
    title: String,
    body: String,
    tags: [String] = [],
    priority: Int = 0,
    provenance: [CoreAgentSkillProvenance] = []
  ) {
    self.id = id
    self.version = version
    self.title = title
    self.body = body
    self.tags = tags
    self.priority = priority
    self.provenance = provenance
  }
}

public struct CoreAgentSkillProvenance: Codable, Equatable, Sendable {
  public let acceptedAt: Date
  public let heldoutSuiteID: String
  public let validationScore: Double
  public let notes: String

  public init(
    acceptedAt: Date = Date(),
    heldoutSuiteID: String,
    validationScore: Double,
    notes: String
  ) {
    self.acceptedAt = acceptedAt
    self.heldoutSuiteID = heldoutSuiteID
    self.validationScore = validationScore
    self.notes = notes
  }
}

public struct CoreAgentSkillValidationResult: Codable, Equatable, Sendable {
  public let score: Double
  public let heldoutSuiteID: String
  public let passed: Bool
  public let notes: String

  public init(score: Double, heldoutSuiteID: String, passed: Bool, notes: String) {
    self.score = score
    self.heldoutSuiteID = heldoutSuiteID
    self.passed = passed
    self.notes = notes
  }
}

public struct CoreAgentSkillRolloutEvidence: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let taskID: String
  public let transcriptDigest: String
  public let toolEventDigest: String
  public let verifierFeedback: String
  public let score: Double
  public let metadata: [String: String]

  public init(
    id: String,
    taskID: String,
    transcriptDigest: String,
    toolEventDigest: String,
    verifierFeedback: String,
    score: Double,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.taskID = taskID
    self.transcriptDigest = transcriptDigest
    self.toolEventDigest = toolEventDigest
    self.verifierFeedback = verifierFeedback
    self.score = score
    self.metadata = metadata
  }
}

public struct CoreAgentSkillEngineTraceHarvester: Sendable {
  private let engineStore: any CoreAgentEngineStore

  public init(engineStore: any CoreAgentEngineStore) {
    self.engineStore = engineStore
  }

  public func harvest(
    projectID: String,
    threadID: String? = nil
  ) async -> [CoreAgentSkillRolloutEvidence] {
    let traces = await engineStore.traces(projectID: projectID, threadID: threadID)
      .filter(Self.isHarvestable)
    let issueByRunID = Self.issueByRunID(await engineStore.issues(projectID: projectID))
    return traces.map { trace in
      Self.evidence(for: trace, issue: issueByRunID[trace.run.id])
    }
  }

  public static func totalTokenUsage(in traces: [CoreAgentEngineTrace]) -> Int {
    traces.filter(isHarvestable)
      .compactMap(\.run.usage)
      .reduce(CoreAgentUsage.zero) { $0.adding($1) }
      .totalTokenCount
  }

  private static func issueByRunID(
    _ issues: [CoreAgentEngineIssue]
  ) -> [UUID: CoreAgentEngineIssue] {
    var result: [UUID: CoreAgentEngineIssue] = [:]
    for issue in issues.sorted(by: issueSort) {
      for runID in issue.contributingRunIDs where result[runID] == nil {
        result[runID] = issue
      }
    }
    return result
  }

  private static func issueSort(
    lhs: CoreAgentEngineIssue,
    rhs: CoreAgentEngineIssue
  ) -> Bool {
    if lhs.firstSeenAt != rhs.firstSeenAt {
      return lhs.firstSeenAt < rhs.firstSeenAt
    }
    return lhs.id < rhs.id
  }

  private static func evidence(
    for trace: CoreAgentEngineTrace,
    issue: CoreAgentEngineIssue?
  ) -> CoreAgentSkillRolloutEvidence {
    let status = runStatus(trace.run)
    let toolEvents = trace.run.events.filter(isToolEvent)
    var metadata: [String: String] = [
      "source": "coreagent-engine",
      "project_id": trace.projectID,
      "run_id": trace.run.id.uuidString.lowercased(),
      "run_status": status,
      "event_count": "\(trace.run.events.count)",
      "tool_event_count": "\(toolEvents.count)",
    ]
    if let threadID = trace.threadID {
      metadata["thread_id"] = threadID
    }
    if let rootHash = trace.receipt.rootHash {
      metadata["receipt_root_hash"] = rootHash
    }
    if let usage = trace.run.usage {
      metadata["input_tokens"] = "\(usage.inputTokens)"
      metadata["cached_input_tokens"] = "\(usage.cachedInputTokens)"
      metadata["output_tokens"] = "\(usage.outputTokens)"
      metadata["reasoning_tokens"] = "\(usage.reasoningTokens)"
    }
    if let issue {
      metadata["issue_id_digest"] = digest(value: issue.id)
      metadata["issue_status"] = issue.status.rawValue
    }

    return CoreAgentSkillRolloutEvidence(
      id: evidenceID(for: trace),
      taskID: issue.map { safeReference(prefix: "engine-issue", value: $0.id) }
        ?? "run-\(trace.run.id.uuidString.lowercased())",
      transcriptDigest: digest(events: trace.run.events.filter { !isToolEvent($0) }),
      toolEventDigest: digest(events: toolEvents),
      verifierFeedback: issue.map { _ in "engine issue linked" } ?? "engine run \(status)",
      score: score(for: status),
      metadata: metadata
    )
  }

  private static func isHarvestable(_ trace: CoreAgentEngineTrace) -> Bool {
    let status = runStatus(trace.run)
    guard status == "completed" || status == "failed" else {
      return false
    }
    guard trace.receipt.runID == trace.run.id,
      trace.receipt.verify(),
      trace.receipt.receipts.map(\.event) == trace.run.events
    else {
      return false
    }
    return true
  }

  private static func evidenceID(for trace: CoreAgentEngineTrace) -> String {
    let payload = [
      "coreagent-skill-engine-trace-evidence-v1",
      trace.projectID,
      trace.threadID ?? "",
      trace.run.id.uuidString.lowercased(),
      trace.receipt.rootHash ?? "",
    ].joined(separator: "\u{0}")
    return "engine-trace-\(sha256Hex(Data(payload.utf8)).prefix(24))"
  }

  private static func runStatus(_ run: CoreAgentRun) -> String {
    if run.events.contains(where: { $0.kind == .runFailed }) {
      return "failed"
    }
    if run.events.contains(where: { $0.kind == .runCompleted }) {
      return "completed"
    }
    return "unknown"
  }

  private static func score(for status: String) -> Double {
    switch status {
    case "completed":
      1
    case "failed":
      0
    default:
      0.5
    }
  }

  private static func isToolEvent(_ event: CoreAgentEvent) -> Bool {
    switch event.kind {
    case .toolAuthorizationStarted,
      .toolAuthorizationSucceeded,
      .toolAuthorizationDenied,
      .toolAuthorizationCancelled,
      .toolAuthorizationFailed,
      .toolInterventionStarted,
      .toolInterventionApproved,
      .toolInterventionEdited,
      .toolInterventionRejected,
      .toolInterventionResponded,
      .toolInterventionCancelled,
      .toolInterventionFailed,
      .toolExecutionStarted,
      .toolExecutionCompleted,
      .toolExecutionFailed,
      .nativeToolCallRecorded,
      .nativeToolOutputRecorded:
      true
    default:
      false
    }
  }

  private static func digest(events: [CoreAgentEvent]) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let payload = (try? encoder.encode(events)) ?? Data()
    return "sha256:\(sha256Hex(payload))"
  }

  private static func digest(value: String) -> String {
    "sha256:\(sha256Hex(Data(value.utf8)))"
  }

  private static func safeReference(prefix: String, value: String) -> String {
    "\(prefix)-\(sha256Hex(Data(value.utf8)).prefix(24))"
  }
}

public enum CoreAgentSkillReplayMode: String, Codable, Equatable, Sendable {
  case replay
  case dream
}

public struct CoreAgentSkillReplayRequest: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let mode: CoreAgentSkillReplayMode
  public let sourceEvidenceID: String
  public let taskID: String
  public let transcriptDigest: String
  public let toolEventDigest: String
  public let heldoutSuiteID: String
  public let metadata: [String: String]

  public init(
    id: String,
    mode: CoreAgentSkillReplayMode,
    sourceEvidenceID: String,
    taskID: String,
    transcriptDigest: String,
    toolEventDigest: String,
    heldoutSuiteID: String,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.mode = mode
    self.sourceEvidenceID = sourceEvidenceID
    self.taskID = taskID
    self.transcriptDigest = transcriptDigest
    self.toolEventDigest = toolEventDigest
    self.heldoutSuiteID = heldoutSuiteID
    self.metadata = metadata
  }
}

public struct CoreAgentSkillReplayGenerationPolicy: Codable, Equatable, Sendable {
  public let heldoutSuiteID: String
  public let excludedSourceSuiteIDs: Set<String>
  public let includeDreamRolloutsForFailures: Bool
  public let maxRequests: Int?

  public init(
    heldoutSuiteID: String,
    excludedSourceSuiteIDs: Set<String> = [],
    includeDreamRolloutsForFailures: Bool = false,
    maxRequests: Int? = nil
  ) {
    self.heldoutSuiteID = heldoutSuiteID
    self.excludedSourceSuiteIDs = excludedSourceSuiteIDs
    self.includeDreamRolloutsForFailures = includeDreamRolloutsForFailures
    self.maxRequests = maxRequests
  }

  fileprivate func validate() throws {
    guard !heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
    }
    if let maxRequests {
      guard maxRequests > 0 else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "maxRequests must be positive"
        )
      }
    }
  }
}

public struct CoreAgentSkillReplayGenerator: Sendable {
  public init() {}

  public func generate(
    from evidence: [CoreAgentSkillRolloutEvidence],
    policy: CoreAgentSkillReplayGenerationPolicy
  ) throws -> [CoreAgentSkillReplayRequest] {
    try policy.validate()
    var requests: [CoreAgentSkillReplayRequest] = []
    for item in evidence {
      if let sourceSuiteID = item.metadata["suite_id"] {
        guard !policy.excludedSourceSuiteIDs.contains(sourceSuiteID) else { continue }
      } else if !policy.excludedSourceSuiteIDs.isEmpty {
        continue
      }
      append(
        request: Self.request(from: item, mode: .replay, policy: policy),
        to: &requests,
        maxRequests: policy.maxRequests
      )
      guard requests.count < (policy.maxRequests ?? Int.max) else { break }
      if policy.includeDreamRolloutsForFailures,
        item.metadata["run_status"] == "failed"
      {
        append(
          request: Self.request(from: item, mode: .dream, policy: policy),
          to: &requests,
          maxRequests: policy.maxRequests
        )
      }
      guard requests.count < (policy.maxRequests ?? Int.max) else { break }
    }
    return requests
  }

  private func append(
    request: CoreAgentSkillReplayRequest,
    to requests: inout [CoreAgentSkillReplayRequest],
    maxRequests: Int?
  ) {
    guard requests.count < (maxRequests ?? Int.max) else { return }
    requests.append(request)
  }

  private static func request(
    from evidence: CoreAgentSkillRolloutEvidence,
    mode: CoreAgentSkillReplayMode,
    policy: CoreAgentSkillReplayGenerationPolicy
  ) -> CoreAgentSkillReplayRequest {
    var metadata: [String: String] = [
      "source": "coreagent-skill-replay-generator",
      "source_evidence_id": evidence.id,
      "source_task_id": evidence.taskID,
      "source_score": "\(evidence.score)",
    ]
    for key in [
      "project_id",
      "thread_id",
      "run_id",
      "run_status",
      "issue_id_digest",
      "issue_status",
    ] {
      if let value = evidence.metadata[key] {
        metadata["source_\(key)"] = value
      }
    }
    if let sourceSuiteID = evidence.metadata["suite_id"] {
      metadata["source_suite_id"] = sourceSuiteID
    }

    return CoreAgentSkillReplayRequest(
      id: requestID(for: evidence, mode: mode, heldoutSuiteID: policy.heldoutSuiteID),
      mode: mode,
      sourceEvidenceID: evidence.id,
      taskID: evidence.taskID,
      transcriptDigest: evidence.transcriptDigest,
      toolEventDigest: evidence.toolEventDigest,
      heldoutSuiteID: policy.heldoutSuiteID,
      metadata: metadata
    )
  }

  private static func requestID(
    for evidence: CoreAgentSkillRolloutEvidence,
    mode: CoreAgentSkillReplayMode,
    heldoutSuiteID: String
  ) -> String {
    let payload = [
      "coreagent-skill-replay-request-v1",
      mode.rawValue,
      evidence.id,
      evidence.transcriptDigest,
      evidence.toolEventDigest,
      heldoutSuiteID,
    ].joined(separator: "\u{0}")
    return "skill-rollout-\(sha256Hex(Data(payload.utf8)).prefix(24))"
  }
}

public struct CoreAgentSkillReplayOutcome: Codable, Equatable, Sendable {
  public let requestID: String
  public let transcriptDigest: String
  public let toolEventDigest: String
  public let verifierFeedback: String
  public let score: Double

  public init(
    requestID: String,
    transcriptDigest: String,
    toolEventDigest: String,
    verifierFeedback: String,
    score: Double
  ) {
    self.requestID = requestID
    self.transcriptDigest = transcriptDigest
    self.toolEventDigest = toolEventDigest
    self.verifierFeedback = verifierFeedback
    self.score = score
  }
}

public protocol CoreAgentSkillReplayBackend: Sendable {
  func execute(_ request: CoreAgentSkillReplayRequest) async throws
    -> CoreAgentSkillReplayOutcome
}

public struct CoreAgentSkillReplayExecutionPolicy: Codable, Equatable, Sendable {
  public let excludedSourceSuiteIDs: Set<String>

  public init(excludedSourceSuiteIDs: Set<String> = []) {
    self.excludedSourceSuiteIDs = excludedSourceSuiteIDs
  }
}

public struct CoreAgentSkillReplayExecutor: Sendable {
  private let backend: any CoreAgentSkillReplayBackend
  private let policy: CoreAgentSkillReplayExecutionPolicy

  public init(
    backend: any CoreAgentSkillReplayBackend,
    policy: CoreAgentSkillReplayExecutionPolicy = CoreAgentSkillReplayExecutionPolicy()
  ) {
    self.backend = backend
    self.policy = policy
  }

  public func execute(
    _ requests: [CoreAgentSkillReplayRequest]
  ) async throws -> [CoreAgentSkillRolloutEvidence] {
    try Self.validate(requests, policy: policy)
    var evidence: [CoreAgentSkillRolloutEvidence] = []
    for request in requests {
      let outcome = try await backend.execute(request)
      try Self.validate(outcome, for: request)
      evidence.append(Self.evidence(from: outcome, request: request))
    }
    return evidence
  }

  private static func validate(
    _ requests: [CoreAgentSkillReplayRequest],
    policy: CoreAgentSkillReplayExecutionPolicy
  ) throws {
    var seen: Set<String> = []
    for request in requests {
      guard seen.insert(request.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateReplayRequest(request.id)
      }
      guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !request.sourceEvidenceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !request.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "replay request identity fields must be non-empty"
        )
      }
      guard !request.heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
      }
      guard isSHA256Digest(request.transcriptDigest),
        isSHA256Digest(request.toolEventDigest)
      else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "replay request digests must be sha256"
        )
      }
      if let sourceSuiteID = request.metadata["source_suite_id"] {
        let canonicalSourceSuiteID = sourceSuiteID.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalHeldoutSuiteID = request.heldoutSuiteID.trimmingCharacters(
          in: .whitespacesAndNewlines)
        let excludedSourceSuiteIDs = Set(
          policy.excludedSourceSuiteIDs.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
          }
        )
        guard !canonicalSourceSuiteID.isEmpty else {
          throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
            "replay source suite ID cannot be empty"
          )
        }
        guard canonicalSourceSuiteID != canonicalHeldoutSuiteID else {
          throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
            "replay source suite cannot match heldout suite"
          )
        }
        guard !excludedSourceSuiteIDs.contains(canonicalSourceSuiteID) else {
          throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
            "replay source suite is excluded"
          )
        }
      }
    }
  }

  private static func validate(
    _ outcome: CoreAgentSkillReplayOutcome,
    for request: CoreAgentSkillReplayRequest
  ) throws {
    guard outcome.requestID == request.id else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay outcome request ID mismatch"
      )
    }
    guard isSHA256Digest(outcome.transcriptDigest),
      isSHA256Digest(outcome.toolEventDigest)
    else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "replay outcome digests must be sha256"
      )
    }
    guard outcome.score.isFinite, outcome.score >= 0, outcome.score <= 1 else {
      throw CoreAgentSkillOptimizationError.invalidValidationScore(outcome.score)
    }
  }

  private static func evidence(
    from outcome: CoreAgentSkillReplayOutcome,
    request: CoreAgentSkillReplayRequest
  ) -> CoreAgentSkillRolloutEvidence {
    var metadata: [String: String] = [
      "source": "coreagent-skill-replay-executor",
      "suite_id": request.heldoutSuiteID,
      "replay_request_id": request.id,
      "replay_mode": request.mode.rawValue,
      "source_evidence_id": request.sourceEvidenceID,
      "source_transcript_digest": request.transcriptDigest,
      "source_tool_event_digest": request.toolEventDigest,
      "verifier_feedback_digest": "sha256:\(sha256Hex(Data(outcome.verifierFeedback.utf8)))",
    ]
    for key in [
      "source_project_id",
      "source_thread_id",
      "source_run_id",
      "source_run_status",
      "source_issue_id_digest",
      "source_issue_status",
      "source_suite_id",
    ] {
      if let value = request.metadata[key] {
        metadata[key] =
          key == "source_suite_id"
          ? value.trimmingCharacters(in: .whitespacesAndNewlines)
          : value
      }
    }
    return CoreAgentSkillRolloutEvidence(
      id: evidenceID(from: outcome, request: request),
      taskID: request.taskID,
      transcriptDigest: outcome.transcriptDigest,
      toolEventDigest: outcome.toolEventDigest,
      verifierFeedback: "\(request.mode.rawValue) execution completed",
      score: outcome.score,
      metadata: metadata
    )
  }

  private static func evidenceID(
    from outcome: CoreAgentSkillReplayOutcome,
    request: CoreAgentSkillReplayRequest
  ) -> String {
    let payload = [
      "coreagent-skill-replay-evidence-v1",
      request.id,
      request.mode.rawValue,
      request.sourceEvidenceID,
      request.heldoutSuiteID,
      outcome.transcriptDigest,
      outcome.toolEventDigest,
      "\(outcome.score)",
      sha256Hex(Data(outcome.verifierFeedback.utf8)),
    ].joined(separator: "\u{0}")
    return "replay-evidence-\(sha256Hex(Data(payload.utf8)).prefix(24))"
  }
}

public struct CoreAgentSkillModelProposalEvidenceReference:
  Codable, Equatable, Sendable, Identifiable
{
  public let id: String
  public let taskID: String
  public let transcriptDigest: String
  public let toolEventDigest: String
  public let score: Double
  public let metadata: [String: String]

  public init(
    id: String,
    taskID: String,
    transcriptDigest: String,
    toolEventDigest: String,
    score: Double,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.taskID = taskID
    self.transcriptDigest = transcriptDigest
    self.toolEventDigest = toolEventDigest
    self.score = score
    self.metadata = metadata
  }
}

public struct CoreAgentSkillModelProposalRequest: Codable, Equatable, Sendable {
  public let runID: String
  public let skill: CoreAgentSkill
  public let baselineScore: Double
  public let evidence: [CoreAgentSkillModelProposalEvidenceReference]
  public let policy: CoreAgentSkillOptimizationPolicy
  public let maxProposals: Int

  public init(
    runID: String,
    skill: CoreAgentSkill,
    baselineScore: Double,
    evidence: [CoreAgentSkillModelProposalEvidenceReference],
    policy: CoreAgentSkillOptimizationPolicy = CoreAgentSkillOptimizationPolicy(),
    maxProposals: Int = 3
  ) {
    self.runID = runID
    self.skill = skill
    self.baselineScore = baselineScore
    self.evidence = evidence
    self.policy = policy
    self.maxProposals = maxProposals
  }
}

public struct CoreAgentSkillModelProposalCandidate: Equatable, Sendable {
  public let id: String
  public let skillID: CoreAgentSkillID
  public let baselineScore: Double
  public let candidateEdits: [CoreAgentSkillEdit]
  public let validation: CoreAgentSkillValidationResult
  public let evidenceIDs: [String]

  public init(
    id: String,
    skillID: CoreAgentSkillID,
    baselineScore: Double,
    candidateEdits: [CoreAgentSkillEdit],
    validation: CoreAgentSkillValidationResult,
    evidenceIDs: [String]
  ) {
    self.id = id
    self.skillID = skillID
    self.baselineScore = baselineScore
    self.candidateEdits = candidateEdits
    self.validation = validation
    self.evidenceIDs = evidenceIDs
  }
}

public protocol CoreAgentSkillModelProposalBackend: Sendable {
  func generate(
    _ request: CoreAgentSkillModelProposalRequest
  ) async throws -> [CoreAgentSkillModelProposalCandidate]
}

@Generable
private struct CoreAgentSkillFoundationModelsProposalEnvelope: Sendable {
  let proposals: [CoreAgentSkillFoundationModelsProposalDraft]
}

@Generable
private struct CoreAgentSkillFoundationModelsProposalDraft: Sendable {
  let id: String
  let skillID: String
  let baselineScore: Double
  let edits: [CoreAgentSkillFoundationModelsEditDraft]
  let validationScore: Double
  let validationHeldoutSuiteID: String
  let validationPassed: Bool
  let validationNotes: String
  let evidenceIDs: [String]
}

@Generable
private struct CoreAgentSkillFoundationModelsEditDraft: Sendable {
  let operation: String
  let target: String
  let replacement: String
  let appendText: String
}

public struct CoreAgentSkillFoundationModelsProposalBackend:
  CoreAgentSkillModelProposalBackend
{
  private let session: CoreAgentSession

  public init(session: CoreAgentSession) {
    self.session = session
  }

  public func generate(
    _ request: CoreAgentSkillModelProposalRequest
  ) async throws -> [CoreAgentSkillModelProposalCandidate] {
    let sanitizedRequest = try Self.sanitized(request)
    let response = try await session.respond(
      to: try Self.prompt(for: sanitizedRequest),
      generating: CoreAgentSkillFoundationModelsProposalEnvelope.self
    )
    return try Self.candidates(from: response.content, request: sanitizedRequest)
  }

  private static func sanitized(
    _ request: CoreAgentSkillModelProposalRequest
  ) throws -> CoreAgentSkillModelProposalRequest {
    try request.policy.validate()
    guard !request.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal run ID must be non-empty"
      )
    }
    guard request.maxProposals > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal maxProposals must be positive"
      )
    }
    guard request.baselineScore.isFinite,
      request.baselineScore >= 0,
      request.baselineScore <= 1
    else {
      throw CoreAgentSkillOptimizationError.invalidValidationScore(request.baselineScore)
    }
    guard !request.skill.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal skill ID must be non-empty"
      )
    }
    var seenEvidenceIDs: Set<String> = []
    let evidence = try request.evidence.map { reference in
      guard !reference.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !reference.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal evidence identity fields must be non-empty"
        )
      }
      guard seenEvidenceIDs.insert(reference.id).inserted else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal evidence IDs must be unique"
        )
      }
      guard isSHA256Digest(reference.transcriptDigest),
        isSHA256Digest(reference.toolEventDigest)
      else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal evidence digests must be sha256"
        )
      }
      guard reference.score.isFinite, reference.score >= 0, reference.score <= 1
      else {
        throw CoreAgentSkillOptimizationError.invalidValidationScore(reference.score)
      }
      return CoreAgentSkillModelProposalEvidenceReference(
        id: reference.id,
        taskID: reference.taskID,
        transcriptDigest: reference.transcriptDigest,
        toolEventDigest: reference.toolEventDigest,
        score: reference.score,
        metadata: sanitizedModelProposalEvidenceMetadata(reference.metadata)
      )
    }
    return CoreAgentSkillModelProposalRequest(
      runID: request.runID,
      skill: CoreAgentSkill(
        id: request.skill.id,
        version: request.skill.version,
        title: request.skill.title,
        body: request.skill.body,
        tags: request.skill.tags,
        priority: request.skill.priority,
        provenance: []
      ),
      baselineScore: request.baselineScore,
      evidence: evidence,
      policy: request.policy,
      maxProposals: request.maxProposals
    )
  }

  private static func prompt(
    for request: CoreAgentSkillModelProposalRequest
  ) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let requestData = try encoder.encode(request)
    guard let requestJSON = String(data: requestData, encoding: .utf8) else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal request JSON must be UTF-8"
      )
    }
    return """
      Generate CoreAgent SkillOpt model proposal candidates from the sanitized request.
      Use FoundationModels structured generation only; do not return prose outside the schema.
      Return at most maxProposals candidates. Every candidate must reference supplied evidenceIDs.
      Supported edit operation literals:
      - replace: set operation to "replace", target to exact current skill text, and replacement to the new text.
      - append: set operation to "append" and appendText to the text to add.
      Validate against held-out suites only; never use trainingSuiteIDs as validationHeldoutSuiteID.
      Sanitized CoreAgentSkillModelProposalRequest JSON:
      \(requestJSON)
      """
  }

  private static func candidates(
    from envelope: CoreAgentSkillFoundationModelsProposalEnvelope,
    request: CoreAgentSkillModelProposalRequest
  ) throws -> [CoreAgentSkillModelProposalCandidate] {
    guard envelope.proposals.count <= request.maxProposals else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal backend exceeded maxProposals"
      )
    }
    return try envelope.proposals.map { proposal in
      CoreAgentSkillModelProposalCandidate(
        id: proposal.id,
        skillID: CoreAgentSkillID(proposal.skillID),
        baselineScore: proposal.baselineScore,
        candidateEdits: try proposal.edits.map(edit),
        validation: CoreAgentSkillValidationResult(
          score: proposal.validationScore,
          heldoutSuiteID: proposal.validationHeldoutSuiteID,
          passed: proposal.validationPassed,
          notes: proposal.validationNotes
        ),
        evidenceIDs: proposal.evidenceIDs
      )
    }
  }

  private static func edit(
    from draft: CoreAgentSkillFoundationModelsEditDraft
  ) throws -> CoreAgentSkillEdit {
    switch draft.operation {
    case "replace":
      return .replace(target: draft.target, replacement: draft.replacement)
    case "append":
      return .append(draft.appendText)
    default:
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "model proposal edit operation is unsupported"
      )
    }
  }
}

public struct CoreAgentSkillModelProposalGenerator: Sendable {
  private let backend: any CoreAgentSkillModelProposalBackend

  public init(backend: any CoreAgentSkillModelProposalBackend) {
    self.backend = backend
  }

  public func generate(
    runID: String,
    skill: CoreAgentSkill,
    baselineScore: Double,
    evidence: [CoreAgentSkillRolloutEvidence],
    policy: CoreAgentSkillOptimizationPolicy = CoreAgentSkillOptimizationPolicy(),
    maxProposals: Int = 3
  ) async throws -> [CoreAgentSkillSleepOptimizationProposal] {
    let request = try Self.request(
      runID: runID,
      skill: skill,
      baselineScore: baselineScore,
      evidence: evidence,
      policy: policy,
      maxProposals: maxProposals
    )
    let candidates = try await backend.generate(request)
    return try Self.proposals(from: candidates, request: request)
  }

  private static func request(
    runID: String,
    skill: CoreAgentSkill,
    baselineScore: Double,
    evidence: [CoreAgentSkillRolloutEvidence],
    policy: CoreAgentSkillOptimizationPolicy,
    maxProposals: Int
  ) throws -> CoreAgentSkillModelProposalRequest {
    try policy.validate()
    guard !runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal run ID must be non-empty"
      )
    }
    guard maxProposals > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal maxProposals must be positive"
      )
    }
    guard baselineScore.isFinite, baselineScore >= 0, baselineScore <= 1 else {
      throw CoreAgentSkillOptimizationError.invalidValidationScore(baselineScore)
    }
    guard !skill.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal skill ID must be non-empty"
      )
    }
    let references = try evidence.map(sanitizedEvidenceReference)
    try validateUniqueEvidenceIDs(references)
    return CoreAgentSkillModelProposalRequest(
      runID: runID,
      skill: CoreAgentSkill(
        id: skill.id,
        version: skill.version,
        title: skill.title,
        body: skill.body,
        tags: skill.tags,
        priority: skill.priority,
        provenance: []
      ),
      baselineScore: baselineScore,
      evidence: references,
      policy: policy,
      maxProposals: maxProposals
    )
  }

  private static func proposals(
    from candidates: [CoreAgentSkillModelProposalCandidate],
    request: CoreAgentSkillModelProposalRequest
  ) throws -> [CoreAgentSkillSleepOptimizationProposal] {
    guard candidates.count <= request.maxProposals else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal backend exceeded maxProposals"
      )
    }
    var seen: Set<String> = []
    let evidenceByID = Dictionary(uniqueKeysWithValues: request.evidence.map { ($0.id, $0) })
    return try candidates.map { candidate in
      guard isSafeProposalIdentifier(candidate.id) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal candidate ID is invalid"
        )
      }
      guard seen.insert(candidate.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(candidate.id)
      }
      guard candidate.skillID == request.skill.id else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal candidate skill must match request skill"
        )
      }
      guard candidate.baselineScore == request.baselineScore else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal candidate baseline must match request baseline"
        )
      }
      guard !candidate.candidateEdits.isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal candidate edits must be non-empty"
        )
      }
      guard candidate.candidateEdits.count <= request.policy.maxEditsPerProposal else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal candidate exceeds maxEditsPerProposal"
        )
      }
      try validateSkillOptimizationScores(
        candidate.validation,
        baselineScore: candidate.baselineScore
      )
      if request.policy.trainingSuiteIDs.contains(candidate.validation.heldoutSuiteID) {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal validation suite cannot be a training suite"
        )
      }
      _ = try applyEdits(
        candidate.candidateEdits,
        to: request.skill.body,
        limits: request.policy.editLimits
      )
      guard !candidate.evidenceIDs.isEmpty
      else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal evidence IDs must reference supplied evidence"
        )
      }
      guard Set(candidate.evidenceIDs).count == candidate.evidenceIDs.count
      else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal candidate evidence IDs must be unique"
        )
      }
      guard candidate.evidenceIDs.allSatisfy({ evidenceByID[$0] != nil })
      else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal evidence IDs must reference supplied evidence"
        )
      }
      return CoreAgentSkillSleepOptimizationProposal(
        id: candidate.id,
        evidence: candidate.evidenceIDs.compactMap { evidenceByID[$0]?.rolloutEvidence },
        proposal: CoreAgentSkillOptimizationProposal(
          skillID: candidate.skillID,
          baselineScore: candidate.baselineScore,
          candidateEdits: candidate.candidateEdits,
          validation: CoreAgentSkillValidationResult(
            score: candidate.validation.score,
            heldoutSuiteID: candidate.validation.heldoutSuiteID,
            passed: candidate.validation.passed,
            notes: "model proposal \(candidate.id) validation"
          )
        )
      )
    }
  }

  private static func validateUniqueEvidenceIDs(
    _ references: [CoreAgentSkillModelProposalEvidenceReference]
  ) throws {
    var seen: Set<String> = []
    for reference in references {
      guard seen.insert(reference.id).inserted else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "proposal evidence IDs must be unique"
        )
      }
    }
  }

  private static func sanitizedEvidenceReference(
    _ evidence: CoreAgentSkillRolloutEvidence
  ) throws -> CoreAgentSkillModelProposalEvidenceReference {
    guard !evidence.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !evidence.taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal evidence identity fields must be non-empty"
      )
    }
    guard isSHA256Digest(evidence.transcriptDigest),
      isSHA256Digest(evidence.toolEventDigest)
    else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal evidence digests must be sha256"
      )
    }
    guard evidence.score.isFinite, evidence.score >= 0, evidence.score <= 1 else {
      throw CoreAgentSkillOptimizationError.invalidValidationScore(evidence.score)
    }
    return CoreAgentSkillModelProposalEvidenceReference(
      id: evidence.id,
      taskID: evidence.taskID,
      transcriptDigest: evidence.transcriptDigest,
      toolEventDigest: evidence.toolEventDigest,
      score: evidence.score,
      metadata: sanitizedEvidenceMetadata(evidence.metadata)
    )
  }

  private static func sanitizedEvidenceMetadata(
    _ metadata: [String: String]
  ) -> [String: String] {
    sanitizedModelProposalEvidenceMetadata(metadata)
  }
}

extension CoreAgentSkillModelProposalEvidenceReference {
  fileprivate var rolloutEvidence: CoreAgentSkillRolloutEvidence {
    CoreAgentSkillRolloutEvidence(
      id: id,
      taskID: taskID,
      transcriptDigest: transcriptDigest,
      toolEventDigest: toolEventDigest,
      verifierFeedback: "proposal evidence reference",
      score: score,
      metadata: metadata
    )
  }
}

public struct CoreAgentSkillEditLimits: Codable, Equatable, Sendable {
  public let maxEditCharacters: Int
  public let maxResultCharacters: Int

  public init(maxEditCharacters: Int = 4_000, maxResultCharacters: Int = 20_000) {
    self.maxEditCharacters = maxEditCharacters
    self.maxResultCharacters = maxResultCharacters
  }

  public static let `default` = CoreAgentSkillEditLimits()
}

public enum CoreAgentSkillEdit: Codable, Equatable, Sendable {
  case replace(target: String, replacement: String)
  case append(String)

  public func apply(to body: String) throws -> String {
    try apply(to: body, limits: .default)
  }

  public func apply(to body: String, limits: CoreAgentSkillEditLimits) throws -> String {
    switch self {
    case .append(let addition):
      guard addition.count <= limits.maxEditCharacters else {
        throw CoreAgentSkillOptimizationError.editTooLarge
      }
      let result = body + addition
      guard result.count <= limits.maxResultCharacters else {
        throw CoreAgentSkillOptimizationError.resultingSkillTooLarge
      }
      return result
    case .replace(let target, let replacement):
      guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.emptyReplacementTarget
      }
      guard replacement.count <= limits.maxEditCharacters else {
        throw CoreAgentSkillOptimizationError.editTooLarge
      }
      let parts = body.components(separatedBy: target)
      guard parts.count == 2 else {
        throw CoreAgentSkillOptimizationError.replacementTargetNotUnique(target)
      }
      let result = parts[0] + replacement + parts[1]
      guard result.count <= limits.maxResultCharacters else {
        throw CoreAgentSkillOptimizationError.resultingSkillTooLarge
      }
      return result
    }
  }
}

public enum CoreAgentSkillOptimizationError: Error, Equatable, Sendable {
  case missingSkill(CoreAgentSkillID)
  case emptyReplacementTarget
  case replacementTargetNotUnique(String)
  case missingHarnessEvaluation(String)
  case versionCollision(CoreAgentSkillID, Int)
  case duplicateHarnessCandidate(String)
  case duplicateHarnessObjective(CoreAgentHarnessObjectiveID)
  case duplicateHarnessObjectiveEvaluation(String)
  case duplicateOptimizationProposal(String)
  case duplicateReplayRequest(String)
  case noEligibleHarnessCandidate
  case invalidOptimizationPolicy(String)
  case corruptSkillStore(String)
  case editTooLarge
  case resultingSkillTooLarge
  case invalidValidationScore(Double)
  case emptyHeldoutSuiteID
}

public struct CoreAgentSkillOptimizationProposal: Sendable {
  public let skillID: CoreAgentSkillID
  public let baselineScore: Double
  public let candidateEdits: [CoreAgentSkillEdit]
  public let validation: CoreAgentSkillValidationResult

  public init(
    skillID: CoreAgentSkillID,
    baselineScore: Double,
    candidateEdits: [CoreAgentSkillEdit],
    validation: CoreAgentSkillValidationResult
  ) {
    self.skillID = skillID
    self.baselineScore = baselineScore
    self.candidateEdits = candidateEdits
    self.validation = validation
  }
}

public struct CoreAgentSkillOptimizationResult: Equatable, Sendable {
  public let accepted: Bool
  public let skill: CoreAgentSkill
  public let validation: CoreAgentSkillValidationResult
}

public struct CoreAgentRejectedSkillEdit: Codable, Equatable, Sendable {
  public let proposedAt: Date
  public let edits: [CoreAgentSkillEdit]
  public let validation: CoreAgentSkillValidationResult

  public init(
    proposedAt: Date = Date(),
    edits: [CoreAgentSkillEdit],
    validation: CoreAgentSkillValidationResult
  ) {
    self.proposedAt = proposedAt
    self.edits = edits
    self.validation = validation
  }
}

public enum CoreAgentSkillOptimizationRejectionReason:
  String, Codable, Equatable, Sendable
{
  case editBudgetExceeded
  case heldoutSplitLeakage
  case protectedRegionMutation
  case validationDidNotImprove
  case maxAcceptedProposalsReached
  case externalMemoryImport
}

public struct CoreAgentSkillMetaObservation: Codable, Equatable, Sendable {
  public let observedAt: Date
  public let runID: String
  public let proposalID: String
  public let reason: CoreAgentSkillOptimizationRejectionReason
  public let notes: String

  public init(
    observedAt: Date = Date(),
    runID: String,
    proposalID: String,
    reason: CoreAgentSkillOptimizationRejectionReason,
    notes: String
  ) {
    self.observedAt = observedAt
    self.runID = runID
    self.proposalID = proposalID
    self.reason = reason
    self.notes = notes
  }
}

public struct CoreAgentSkillMetaSkillComponent: Codable, Equatable, Sendable {
  public let componentDigest: String
  public let policyVersion: String

  public init(componentDigest: String, policyVersion: String) {
    self.componentDigest = componentDigest
    self.policyVersion = policyVersion
  }
}

public struct CoreAgentSkillMetaSkillBranchSnapshot: Codable, Equatable, Sendable {
  public let branchID: String
  public let parentBranchID: String?
  public let epoch: Int
  public let analyzer: CoreAgentSkillMetaSkillComponent
  public let retriever: CoreAgentSkillMetaSkillComponent
  public let allocator: CoreAgentSkillMetaSkillComponent
  public let proposer: CoreAgentSkillMetaSkillComponent
  public let evolver: CoreAgentSkillMetaSkillComponent
  public let objectiveDigest: String

  public init(
    branchID: String,
    parentBranchID: String? = nil,
    epoch: Int,
    analyzer: CoreAgentSkillMetaSkillComponent,
    retriever: CoreAgentSkillMetaSkillComponent,
    allocator: CoreAgentSkillMetaSkillComponent,
    proposer: CoreAgentSkillMetaSkillComponent,
    evolver: CoreAgentSkillMetaSkillComponent,
    objectiveDigest: String
  ) {
    self.branchID = branchID
    self.parentBranchID = parentBranchID
    self.epoch = epoch
    self.analyzer = analyzer
    self.retriever = retriever
    self.allocator = allocator
    self.proposer = proposer
    self.evolver = evolver
    self.objectiveDigest = objectiveDigest
  }
}

public struct CoreAgentSkillMetaSkillEvolutionRecord: Codable, Equatable, Sendable {
  public let runID: String
  public let branchID: String
  public let previousEpoch: Int
  public let nextEpoch: Int
  public let acceptedProposalIDs: [String]
  public let rejectedProposalIDs: [String]
  public let frontierRejectedProposalIDs: [String]
  public let sleepAcceptedProposalIDs: [String]
  public let sleepRejectedProposalIDs: [String]
  public let evidenceDigest: String

  public init(
    runID: String,
    branchID: String,
    previousEpoch: Int,
    nextEpoch: Int,
    acceptedProposalIDs: [String],
    rejectedProposalIDs: [String],
    frontierRejectedProposalIDs: [String] = [],
    sleepAcceptedProposalIDs: [String]? = nil,
    sleepRejectedProposalIDs: [String] = [],
    evidenceDigest: String
  ) {
    self.runID = runID
    self.branchID = branchID
    self.previousEpoch = previousEpoch
    self.nextEpoch = nextEpoch
    self.acceptedProposalIDs = acceptedProposalIDs
    self.rejectedProposalIDs = rejectedProposalIDs
    self.frontierRejectedProposalIDs = frontierRejectedProposalIDs
    self.sleepAcceptedProposalIDs = sleepAcceptedProposalIDs ?? acceptedProposalIDs
    self.sleepRejectedProposalIDs = sleepRejectedProposalIDs
    self.evidenceDigest = evidenceDigest
  }

  private enum CodingKeys: String, CodingKey {
    case runID
    case branchID
    case previousEpoch
    case nextEpoch
    case acceptedProposalIDs
    case rejectedProposalIDs
    case frontierRejectedProposalIDs
    case sleepAcceptedProposalIDs
    case sleepRejectedProposalIDs
    case evidenceDigest
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    runID = try container.decode(String.self, forKey: .runID)
    branchID = try container.decode(String.self, forKey: .branchID)
    previousEpoch = try container.decode(Int.self, forKey: .previousEpoch)
    nextEpoch = try container.decode(Int.self, forKey: .nextEpoch)
    acceptedProposalIDs = try container.decode([String].self, forKey: .acceptedProposalIDs)
    rejectedProposalIDs = try container.decode([String].self, forKey: .rejectedProposalIDs)
    frontierRejectedProposalIDs =
      try container.decodeIfPresent([String].self, forKey: .frontierRejectedProposalIDs)
      ?? rejectedProposalIDs
    sleepAcceptedProposalIDs =
      try container.decodeIfPresent([String].self, forKey: .sleepAcceptedProposalIDs)
      ?? acceptedProposalIDs
    sleepRejectedProposalIDs =
      try container.decodeIfPresent([String].self, forKey: .sleepRejectedProposalIDs)
      ?? []
    evidenceDigest = try container.decode(String.self, forKey: .evidenceDigest)
  }
}

public struct CoreAgentSkillOptimizerMemory: Codable, Equatable, Sendable {
  public var rejectedEdits: [CoreAgentRejectedSkillEdit]
  public var metaObservations: [CoreAgentSkillMetaObservation]
  public var metaSkillSnapshots: [CoreAgentSkillMetaSkillBranchSnapshot]
  public var metaSkillEvolutionRecords: [CoreAgentSkillMetaSkillEvolutionRecord]

  public init(
    rejectedEdits: [CoreAgentRejectedSkillEdit] = [],
    metaObservations: [CoreAgentSkillMetaObservation] = [],
    metaSkillSnapshots: [CoreAgentSkillMetaSkillBranchSnapshot] = [],
    metaSkillEvolutionRecords: [CoreAgentSkillMetaSkillEvolutionRecord] = []
  ) {
    self.rejectedEdits = rejectedEdits
    self.metaObservations = metaObservations
    self.metaSkillSnapshots = metaSkillSnapshots
    self.metaSkillEvolutionRecords = metaSkillEvolutionRecords
  }

  private enum CodingKeys: String, CodingKey {
    case rejectedEdits
    case metaObservations
    case metaSkillSnapshots
    case metaSkillEvolutionRecords
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    rejectedEdits =
      try container.decodeIfPresent([CoreAgentRejectedSkillEdit].self, forKey: .rejectedEdits) ?? []
    metaObservations =
      try container.decodeIfPresent([CoreAgentSkillMetaObservation].self, forKey: .metaObservations)
      ?? []
    metaSkillSnapshots =
      try container.decodeIfPresent(
        [CoreAgentSkillMetaSkillBranchSnapshot].self, forKey: .metaSkillSnapshots)
      ?? []
    metaSkillEvolutionRecords =
      try container.decodeIfPresent(
        [CoreAgentSkillMetaSkillEvolutionRecord].self, forKey: .metaSkillEvolutionRecords)
      ?? []
  }
}

public protocol CoreAgentSkillStore: Sendable {
  func save(_ skill: CoreAgentSkill) async throws
  func currentSkill(id: CoreAgentSkillID) async -> CoreAgentSkill?
  func allCurrentSkills() async -> [CoreAgentSkill]
  func optimizerMemory(skillID: CoreAgentSkillID) async -> CoreAgentSkillOptimizerMemory
  func recordRejected(_ rejected: CoreAgentRejectedSkillEdit, skillID: CoreAgentSkillID)
    async throws
  func recordMetaObservation(
    _ observation: CoreAgentSkillMetaObservation,
    skillID: CoreAgentSkillID
  ) async throws
  func recordMetaSkillSnapshot(
    _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
    skillID: CoreAgentSkillID
  ) async throws
  func recordMetaSkillEvolution(
    _ record: CoreAgentSkillMetaSkillEvolutionRecord,
    skillID: CoreAgentSkillID
  ) async throws
}

public actor InMemoryCoreAgentSkillStore: CoreAgentSkillStore {
  private var historyByID: [CoreAgentSkillID: [CoreAgentSkill]] = [:]
  private var memoryByID: [CoreAgentSkillID: CoreAgentSkillOptimizerMemory] = [:]

  public init() {}

  public func save(_ skill: CoreAgentSkill) async throws {
    if historyByID[skill.id, default: []].contains(where: { $0.version == skill.version }) {
      throw CoreAgentSkillOptimizationError.versionCollision(skill.id, skill.version)
    }
    historyByID[skill.id, default: []].append(skill)
    historyByID[skill.id]?.sort { $0.version < $1.version }
  }

  public func currentSkill(id: CoreAgentSkillID) async -> CoreAgentSkill? {
    historyByID[id]?.max { $0.version < $1.version }
  }

  public func allCurrentSkills() async -> [CoreAgentSkill] {
    historyByID.values
      .compactMap { $0.max { $0.version < $1.version } }
      .sorted { lhs, rhs in
        if lhs.priority != rhs.priority {
          return lhs.priority > rhs.priority
        }
        return lhs.id.rawValue < rhs.id.rawValue
      }
  }

  public func optimizerMemory(skillID: CoreAgentSkillID) async -> CoreAgentSkillOptimizerMemory {
    memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
  }

  public func recordRejected(
    _ rejected: CoreAgentRejectedSkillEdit,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    memory.rejectedEdits.append(rejected)
    memoryByID[skillID] = memory
  }

  public func recordMetaObservation(
    _ observation: CoreAgentSkillMetaObservation,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    memory.metaObservations.append(observation)
    memoryByID[skillID] = memory
  }

  public func recordMetaSkillSnapshot(
    _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    try appendMetaSkillSnapshot(snapshot, to: &memory)
    memoryByID[skillID] = memory
  }

  public func recordMetaSkillEvolution(
    _ record: CoreAgentSkillMetaSkillEvolutionRecord,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    try appendMetaSkillEvolution(record, to: &memory)
    memoryByID[skillID] = memory
  }
}

public actor FileCoreAgentSkillStore: CoreAgentSkillStore {
  private let rootDirectory: URL

  public init(rootDirectory: URL) throws {
    self.rootDirectory = rootDirectory
    try FileManager.default.createDirectory(
      at: Self.skillsDirectory(rootDirectory: rootDirectory),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: Self.memoryDirectory(rootDirectory: rootDirectory),
      withIntermediateDirectories: true
    )
  }

  public func save(_ skill: CoreAgentSkill) async throws {
    let directory = skillDirectory(for: skill.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = skillURL(id: skill.id, version: skill.version)
    let data = try encoded(skill)
    do {
      try writeNewFile(data, to: url)
    } catch FileCoreAgentSkillStoreError.fileAlreadyExists {
      throw CoreAgentSkillOptimizationError.versionCollision(skill.id, skill.version)
    }
  }

  public func currentSkill(id: CoreAgentSkillID) async -> CoreAgentSkill? {
    skillHistory(id: id)?.max { $0.version < $1.version }
  }

  public func allCurrentSkills() async -> [CoreAgentSkill] {
    guard
      let directories = try? FileManager.default.contentsOfDirectory(
        at: Self.skillsDirectory(rootDirectory: rootDirectory),
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    else {
      return []
    }
    return
      directories
      .filter { url in
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      }
      .compactMap { currentSkill(in: $0) }
      .sorted { lhs, rhs in
        if lhs.priority != rhs.priority {
          return lhs.priority > rhs.priority
        }
        return lhs.id.rawValue < rhs.id.rawValue
      }
  }

  public func optimizerMemory(skillID: CoreAgentSkillID) async -> CoreAgentSkillOptimizerMemory {
    readMemory(skillID: skillID) ?? CoreAgentSkillOptimizerMemory()
  }

  public func recordRejected(
    _ rejected: CoreAgentRejectedSkillEdit,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = try readMemoryForMutation(skillID: skillID)
    memory.rejectedEdits.append(rejected)
    try write(memory, to: memoryURL(for: skillID))
  }

  public func recordMetaObservation(
    _ observation: CoreAgentSkillMetaObservation,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = try readMemoryForMutation(skillID: skillID)
    memory.metaObservations.append(observation)
    try write(memory, to: memoryURL(for: skillID))
  }

  public func recordMetaSkillSnapshot(
    _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = try readMemoryForMutation(skillID: skillID)
    try appendMetaSkillSnapshot(snapshot, to: &memory)
    try write(memory, to: memoryURL(for: skillID))
  }

  public func recordMetaSkillEvolution(
    _ record: CoreAgentSkillMetaSkillEvolutionRecord,
    skillID: CoreAgentSkillID
  ) async throws {
    var memory = try readMemoryForMutation(skillID: skillID)
    try appendMetaSkillEvolution(record, to: &memory)
    try write(memory, to: memoryURL(for: skillID))
  }

  @discardableResult
  public func exportBestSkillMarkdown(
    id: CoreAgentSkillID,
    to directory: URL,
    filename: String = "best_skill.md"
  ) async throws -> URL {
    guard let skill = await currentSkill(id: id) else {
      throw CoreAgentSkillOptimizationError.missingSkill(id)
    }
    try validateExportFilename(filename)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: filename)
    try CoreAgentSkillExporter.bestSkillMarkdown(skill).write(
      to: url,
      atomically: true,
      encoding: .utf8
    )
    return url
  }

  private func skillHistory(id: CoreAgentSkillID) -> [CoreAgentSkill]? {
    let directory = skillDirectory(for: id)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return []
    }
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    else {
      return nil
    }
    var skills: [CoreAgentSkill] = []
    for url in urls where url.pathExtension == "json" {
      guard let skill: CoreAgentSkill = read(url),
        skill.id == id,
        rowFilenameMatches(url: url, skill: skill)
      else {
        return nil
      }
      skills.append(skill)
    }
    return skills.sorted { $0.version < $1.version }
  }

  private func currentSkill(in directory: URL) -> CoreAgentSkill? {
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    else {
      return nil
    }
    var skills: [CoreAgentSkill] = []
    for url in urls where url.pathExtension == "json" {
      guard let skill: CoreAgentSkill = read(url),
        rowFilenameMatches(url: url, skill: skill),
        skillDirectory(for: skill.id).standardizedFileURL == directory.standardizedFileURL
      else {
        return nil
      }
      skills.append(skill)
    }
    return skills.max { $0.version < $1.version }
  }

  private func readMemory(skillID: CoreAgentSkillID) -> CoreAgentSkillOptimizerMemory? {
    read(memoryURL(for: skillID))
  }

  private func readMemoryForMutation(
    skillID: CoreAgentSkillID
  ) throws -> CoreAgentSkillOptimizerMemory {
    let url = memoryURL(for: skillID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return CoreAgentSkillOptimizerMemory()
    }
    guard let memory: CoreAgentSkillOptimizerMemory = read(url) else {
      throw CoreAgentSkillOptimizationError.corruptSkillStore(
        "optimizer memory could not be decoded for \(skillID.rawValue)"
      )
    }
    return memory
  }

  private func skillDirectory(for id: CoreAgentSkillID) -> URL {
    Self.skillsDirectory(rootDirectory: rootDirectory)
      .appending(
        path: Self.pathComponent(prefix: "skill", value: id.rawValue), directoryHint: .isDirectory)
  }

  private func skillURL(id: CoreAgentSkillID, version: Int) -> URL {
    skillDirectory(for: id).appending(path: "version-\(version).json")
  }

  private func memoryURL(for id: CoreAgentSkillID) -> URL {
    Self.memoryDirectory(rootDirectory: rootDirectory)
      .appending(
        path: "\(Self.pathComponent(prefix: "skill", value: id.rawValue))-optimizer-memory.json")
  }

  private func rowFilenameMatches(url: URL, skill: CoreAgentSkill) -> Bool {
    url.lastPathComponent == "version-\(skill.version).json"
  }

  private func validateExportFilename(_ filename: String) throws {
    guard !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      filename == URL(fileURLWithPath: filename).lastPathComponent,
      !filename.contains("/"),
      !filename.contains("\\")
    else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "export filename must be a plain file name"
      )
    }
  }

  private static func skillsDirectory(rootDirectory: URL) -> URL {
    rootDirectory.appending(path: "skills", directoryHint: .isDirectory)
  }

  private static func memoryDirectory(rootDirectory: URL) -> URL {
    rootDirectory.appending(path: "optimizer-memory", directoryHint: .isDirectory)
  }

  private static func pathComponent(prefix: String, value: String) -> String {
    "\(prefix)-\(sha256Hex(Data(value.utf8)))"
  }

  private func read<Value: Decodable>(_ url: URL) -> Value? {
    guard let data = try? Data(contentsOf: url) else {
      return nil
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try? decoder.decode(Value.self, from: data)
  }

  private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
    try encoded(value).write(to: url, options: [.atomic])
  }

  private func writeNewFile(_ data: Data, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      if errno == EEXIST {
        throw FileCoreAgentSkillStoreError.fileAlreadyExists
      }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      try? handle.close()
      throw error
    }
  }

  private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
  }
}

private enum FileCoreAgentSkillStoreError: Error {
  case fileAlreadyExists
}

private func appendMetaSkillSnapshot(
  _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
  to memory: inout CoreAgentSkillOptimizerMemory
) throws {
  try validateMetaSkillSnapshot(snapshot)
  guard
    !memory.metaSkillSnapshots.contains(where: {
      $0.branchID == snapshot.branchID && $0.epoch == snapshot.epoch
    })
  else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill snapshot branch epoch already recorded"
    )
  }
  memory.metaSkillSnapshots.append(snapshot)
}

private func appendMetaSkillEvolution(
  _ record: CoreAgentSkillMetaSkillEvolutionRecord,
  to memory: inout CoreAgentSkillOptimizerMemory
) throws {
  try validateMetaSkillEvolutionRecord(record)
  guard
    !memory.metaSkillEvolutionRecords.contains(where: {
      $0.runID == record.runID
        && $0.branchID == record.branchID
        && $0.nextEpoch == record.nextEpoch
    })
  else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution record already exists"
    )
  }
  memory.metaSkillEvolutionRecords.append(record)
}

private func validateMetaSkillSnapshot(
  _ snapshot: CoreAgentSkillMetaSkillBranchSnapshot
) throws {
  guard isSafeProposalIdentifier(snapshot.branchID) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill branch ID is invalid"
    )
  }
  if let parentBranchID = snapshot.parentBranchID {
    guard isSafeProposalIdentifier(parentBranchID) else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill parent branch ID is invalid"
      )
    }
  }
  guard snapshot.epoch >= 0 else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill epoch must be non-negative"
    )
  }
  try validateMetaSkillComponent(snapshot.analyzer)
  try validateMetaSkillComponent(snapshot.retriever)
  try validateMetaSkillComponent(snapshot.allocator)
  try validateMetaSkillComponent(snapshot.proposer)
  try validateMetaSkillComponent(snapshot.evolver)
  guard isSHA256Digest(snapshot.objectiveDigest) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill objective digest must be lowercase sha256"
    )
  }
}

private func validateMetaSkillComponent(
  _ component: CoreAgentSkillMetaSkillComponent
) throws {
  guard isSHA256Digest(component.componentDigest) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill component digest must be lowercase sha256"
    )
  }
  let policyVersion = component.policyVersion.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !policyVersion.isEmpty,
    policyVersion.count <= 128,
    !policyVersion.contains("\n"),
    !policyVersion.contains("\r")
  else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill component policy version is invalid"
    )
  }
}

private func validateMetaSkillEvolutionRecord(
  _ record: CoreAgentSkillMetaSkillEvolutionRecord
) throws {
  guard isSafeProposalIdentifier(record.runID) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution run ID is invalid"
    )
  }
  guard isSafeProposalIdentifier(record.branchID) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill branch ID is invalid"
    )
  }
  guard record.previousEpoch >= 0 else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution previous epoch must be non-negative"
    )
  }
  guard record.nextEpoch > record.previousEpoch else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution epoch must advance"
    )
  }
  guard isSHA256Digest(record.evidenceDigest) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill evolution evidence digest must be lowercase sha256"
    )
  }
  try validateMetaSkillProposalIDs(record.acceptedProposalIDs)
  try validateMetaSkillProposalIDs(record.rejectedProposalIDs)
  try validateMetaSkillProposalIDs(record.frontierRejectedProposalIDs)
  try validateMetaSkillProposalIDs(record.sleepAcceptedProposalIDs)
  try validateMetaSkillProposalIDs(record.sleepRejectedProposalIDs)
  guard Set(record.acceptedProposalIDs).isDisjoint(with: Set(record.rejectedProposalIDs)) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill accepted and rejected proposals must not overlap"
    )
  }
  guard record.acceptedProposalIDs == record.sleepAcceptedProposalIDs else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill accepted proposals must match sleep accepted proposals"
    )
  }
  guard
    record.rejectedProposalIDs
      == orderedUnique(
        record.frontierRejectedProposalIDs + record.sleepRejectedProposalIDs
      )
  else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "meta-skill rejected proposals must match frontier plus sleep rejected proposals"
    )
  }
}

private func validateMetaSkillProposalIDs(_ proposalIDs: [String]) throws {
  var seen: Set<String> = []
  for proposalID in proposalIDs {
    guard isSafeProposalIdentifier(proposalID) else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill proposal ID is invalid"
      )
    }
    guard seen.insert(proposalID).inserted else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill proposal IDs must be unique"
      )
    }
  }
}

private func orderedUnique(_ values: [String]) -> [String] {
  var seen: Set<String> = []
  var result: [String] = []
  for value in values where seen.insert(value).inserted {
    result.append(value)
  }
  return result
}

public struct CoreAgentSkillCurationQuery: Sendable {
  public let tags: Set<String>
  public let maxCharacters: Int

  public init(tags: Set<String>, maxCharacters: Int) {
    self.tags = tags
    self.maxCharacters = maxCharacters
  }

  public init(tags: [String], maxCharacters: Int) {
    self.init(tags: Set(tags), maxCharacters: maxCharacters)
  }
}

public struct CoreAgentSkillCurator: Sendable {
  private let store: any CoreAgentSkillStore

  public init(store: any CoreAgentSkillStore) {
    self.store = store
  }

  public func curate(query: CoreAgentSkillCurationQuery) async -> [CoreAgentSkill] {
    var remaining = max(0, query.maxCharacters)
    var selected: [CoreAgentSkill] = []
    for skill in await store.allCurrentSkills() {
      guard !Set(skill.tags).isDisjoint(with: query.tags) else { continue }
      guard skill.body.count <= remaining else { continue }
      selected.append(skill)
      remaining -= skill.body.count
    }
    return selected
  }
}

public struct CoreAgentSkillOptimizer: Sendable {
  private let store: any CoreAgentSkillStore

  public init(store: any CoreAgentSkillStore) {
    self.store = store
  }

  public func propose(
    _ proposal: CoreAgentSkillOptimizationProposal
  ) async throws -> CoreAgentSkillOptimizationResult {
    try await propose(proposal, policy: CoreAgentSkillOptimizationPolicy())
  }

  public func propose(
    _ proposal: CoreAgentSkillOptimizationProposal,
    policy: CoreAgentSkillOptimizationPolicy
  ) async throws -> CoreAgentSkillOptimizationResult {
    try policy.validate()
    guard let current = await store.currentSkill(id: proposal.skillID) else {
      throw CoreAgentSkillOptimizationError.missingSkill(proposal.skillID)
    }
    try validateSkillOptimizationScores(proposal.validation, baselineScore: proposal.baselineScore)
    if let reason = Self.policyRejectionReason(
      proposal,
      current: current,
      policy: policy
    ) {
      return try await reject(proposal, current: current, reason: reason)
    }

    let candidateBody = try applyEdits(
      proposal.candidateEdits,
      to: current.body,
      limits: policy.editLimits
    )

    let next = CoreAgentSkill(
      id: current.id,
      version: current.version + 1,
      title: current.title,
      body: candidateBody,
      tags: current.tags,
      priority: current.priority,
      provenance: current.provenance + [
        CoreAgentSkillProvenance(
          heldoutSuiteID: proposal.validation.heldoutSuiteID,
          validationScore: proposal.validation.score,
          notes: proposal.validation.notes
        )
      ]
    )
    try await store.save(next)
    return CoreAgentSkillOptimizationResult(
      accepted: true,
      skill: next,
      validation: proposal.validation
    )
  }

  private func reject(
    _ proposal: CoreAgentSkillOptimizationProposal,
    current: CoreAgentSkill,
    reason _: CoreAgentSkillOptimizationRejectionReason
  ) async throws -> CoreAgentSkillOptimizationResult {
    try await store.recordRejected(
      CoreAgentRejectedSkillEdit(
        edits: proposal.candidateEdits,
        validation: proposal.validation
      ),
      skillID: proposal.skillID
    )
    return CoreAgentSkillOptimizationResult(
      accepted: false,
      skill: current,
      validation: proposal.validation
    )
  }

  private static func policyRejectionReason(
    _ proposal: CoreAgentSkillOptimizationProposal,
    current: CoreAgentSkill,
    policy: CoreAgentSkillOptimizationPolicy
  ) -> CoreAgentSkillOptimizationRejectionReason? {
    if proposal.candidateEdits.count > policy.maxEditsPerProposal {
      return .editBudgetExceeded
    }
    if policy.trainingSuiteIDs.contains(proposal.validation.heldoutSuiteID) {
      return .heldoutSplitLeakage
    }
    if editsProtectedRegion(
      proposal.candidateEdits,
      in: current.body,
      regions: policy.protectedRegions
    ) {
      return .protectedRegionMutation
    }
    if editsExceedLimits(proposal.candidateEdits, body: current.body, limits: policy.editLimits) {
      return .editBudgetExceeded
    }
    let delta = proposal.validation.score - proposal.baselineScore
    guard proposal.validation.passed,
      proposal.validation.score > proposal.baselineScore,
      delta >= policy.minimumScoreDelta
    else {
      return .validationDidNotImprove
    }
    return nil
  }
}

public struct CoreAgentSkillProtectedRegion: Codable, Equatable, Sendable {
  public let name: String
  public let startMarker: String
  public let endMarker: String

  public init(name: String, startMarker: String, endMarker: String) {
    self.name = name
    self.startMarker = startMarker
    self.endMarker = endMarker
  }

  public static let skillOptSlowUpdate = CoreAgentSkillProtectedRegion(
    name: "skillopt-slow-update",
    startMarker: "<!-- coreagent-slow-update:start -->",
    endMarker: "<!-- coreagent-slow-update:end -->"
  )
}

public struct CoreAgentSkillOptimizationPolicy: Codable, Equatable, Sendable {
  public let maxEditsPerProposal: Int
  public let maxAcceptedProposalsPerRun: Int
  public let minimumScoreDelta: Double
  public let trainingSuiteIDs: Set<String>
  public let protectedRegions: [CoreAgentSkillProtectedRegion]
  public let editLimits: CoreAgentSkillEditLimits

  public init(
    maxEditsPerProposal: Int = 3,
    maxAcceptedProposalsPerRun: Int = 1,
    minimumScoreDelta: Double = 0,
    trainingSuiteIDs: Set<String> = [],
    protectedRegions: [CoreAgentSkillProtectedRegion] = [],
    editLimits: CoreAgentSkillEditLimits = .default
  ) {
    self.maxEditsPerProposal = maxEditsPerProposal
    self.maxAcceptedProposalsPerRun = maxAcceptedProposalsPerRun
    self.minimumScoreDelta = minimumScoreDelta
    self.trainingSuiteIDs = trainingSuiteIDs
    self.protectedRegions = protectedRegions
    self.editLimits = editLimits
  }

  func validate() throws {
    guard maxEditsPerProposal > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxEditsPerProposal must be positive"
      )
    }
    guard maxAcceptedProposalsPerRun > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxAcceptedProposalsPerRun must be positive"
      )
    }
    guard minimumScoreDelta >= 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "minimumScoreDelta must be non-negative"
      )
    }
    guard editLimits.maxEditCharacters > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxEditCharacters must be positive"
      )
    }
    guard editLimits.maxResultCharacters > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "maxResultCharacters must be positive"
      )
    }
    for region in protectedRegions {
      guard !region.startMarker.isEmpty, !region.endMarker.isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "protected region markers must be non-empty"
        )
      }
    }
  }
}

public struct CoreAgentSkillSleepOptimizationProposal: Sendable {
  public let id: String
  public let evidence: [CoreAgentSkillRolloutEvidence]
  public let proposal: CoreAgentSkillOptimizationProposal

  public init(
    id: String,
    evidence: [CoreAgentSkillRolloutEvidence] = [],
    proposal: CoreAgentSkillOptimizationProposal
  ) {
    self.id = id
    self.evidence = evidence
    self.proposal = proposal
  }
}

public struct CoreAgentSkillSleepOptimizationRequest: Sendable {
  public let runID: String
  public let proposals: [CoreAgentSkillSleepOptimizationProposal]
  public let policy: CoreAgentSkillOptimizationPolicy

  public init(
    runID: String,
    proposals: [CoreAgentSkillSleepOptimizationProposal],
    policy: CoreAgentSkillOptimizationPolicy = CoreAgentSkillOptimizationPolicy()
  ) {
    self.runID = runID
    self.proposals = proposals
    self.policy = policy
  }
}

public enum CoreAgentSkillOptimizationDecision: Equatable, Sendable {
  case accepted
  case rejected(CoreAgentSkillOptimizationRejectionReason)
}

public struct CoreAgentSkillSleepOptimizationEntry: Equatable, Sendable {
  public let proposalID: String
  public let skillID: CoreAgentSkillID
  public let decision: CoreAgentSkillOptimizationDecision
  public let skillVersionBefore: Int
  public let skillVersionAfter: Int?
  public let baselineScore: Double
  public let validation: CoreAgentSkillValidationResult
  public let evidenceIDs: [String]

  public init(
    proposalID: String,
    skillID: CoreAgentSkillID,
    decision: CoreAgentSkillOptimizationDecision,
    skillVersionBefore: Int,
    skillVersionAfter: Int?,
    baselineScore: Double,
    validation: CoreAgentSkillValidationResult,
    evidenceIDs: [String]
  ) {
    self.proposalID = proposalID
    self.skillID = skillID
    self.decision = decision
    self.skillVersionBefore = skillVersionBefore
    self.skillVersionAfter = skillVersionAfter
    self.baselineScore = baselineScore
    self.validation = validation
    self.evidenceIDs = evidenceIDs
  }
}

public struct CoreAgentSkillSleepOptimizationReport: Equatable, Sendable {
  public let runID: String
  public let entries: [CoreAgentSkillSleepOptimizationEntry]

  public init(runID: String, entries: [CoreAgentSkillSleepOptimizationEntry]) {
    self.runID = runID
    self.entries = entries
  }

  public var acceptedCount: Int {
    entries.filter { $0.decision == .accepted }.count
  }

  public var rejectedCount: Int {
    entries.count - acceptedCount
  }
}

public struct CoreAgentSkillSleepOptimizer: Sendable {
  private let store: any CoreAgentSkillStore
  private let optimizer: CoreAgentSkillOptimizer

  public init(store: any CoreAgentSkillStore) {
    self.store = store
    self.optimizer = CoreAgentSkillOptimizer(store: store)
  }

  public func run(
    _ request: CoreAgentSkillSleepOptimizationRequest
  ) async throws -> CoreAgentSkillSleepOptimizationReport {
    try request.policy.validate()
    try validateUniqueProposalIDs(request.proposals)
    try await preflight(request)
    var entries: [CoreAgentSkillSleepOptimizationEntry] = []
    var acceptedCount = 0
    for candidate in request.proposals {
      let proposal = candidate.proposal
      guard let current = await store.currentSkill(id: proposal.skillID) else {
        throw CoreAgentSkillOptimizationError.missingSkill(proposal.skillID)
      }
      if acceptedCount >= request.policy.maxAcceptedProposalsPerRun {
        entries.append(
          try await reject(
            candidate,
            current: current,
            request: request,
            reason: .maxAcceptedProposalsReached
          )
        )
        continue
      }
      if proposal.candidateEdits.count > request.policy.maxEditsPerProposal {
        entries.append(
          try await reject(
            candidate,
            current: current,
            request: request,
            reason: .editBudgetExceeded
          )
        )
        continue
      }
      if request.policy.trainingSuiteIDs.contains(proposal.validation.heldoutSuiteID) {
        entries.append(
          try await reject(
            candidate,
            current: current,
            request: request,
            reason: .heldoutSplitLeakage
          )
        )
        continue
      }
      if editsProtectedRegion(
        proposal.candidateEdits,
        in: current.body,
        regions: request.policy.protectedRegions
      ) {
        entries.append(
          try await reject(
            candidate,
            current: current,
            request: request,
            reason: .protectedRegionMutation
          )
        )
        continue
      }
      if editsExceedLimits(
        proposal.candidateEdits,
        body: current.body,
        limits: request.policy.editLimits
      ) {
        entries.append(
          try await reject(
            candidate,
            current: current,
            request: request,
            reason: .editBudgetExceeded
          )
        )
        continue
      }
      let delta = proposal.validation.score - proposal.baselineScore
      guard proposal.validation.passed,
        proposal.validation.score > proposal.baselineScore,
        delta >= request.policy.minimumScoreDelta
      else {
        entries.append(
          try await reject(
            candidate,
            current: current,
            request: request,
            reason: .validationDidNotImprove
          )
        )
        continue
      }

      let result = try await optimizer.propose(proposal, policy: request.policy)
      if result.accepted {
        acceptedCount += 1
        entries.append(
          CoreAgentSkillSleepOptimizationEntry(
            proposalID: candidate.id,
            skillID: proposal.skillID,
            decision: .accepted,
            skillVersionBefore: current.version,
            skillVersionAfter: result.skill.version,
            baselineScore: proposal.baselineScore,
            validation: proposal.validation,
            evidenceIDs: candidate.evidence.map(\.id)
          )
        )
      } else {
        entries.append(
          try await reject(
            candidate,
            current: current,
            request: request,
            reason: .validationDidNotImprove
          )
        )
      }
    }
    return CoreAgentSkillSleepOptimizationReport(runID: request.runID, entries: entries)
  }

  private func preflight(_ request: CoreAgentSkillSleepOptimizationRequest) async throws {
    var simulatedSkillsByID: [CoreAgentSkillID: CoreAgentSkill] = [:]
    var acceptedCount = 0
    for candidate in request.proposals {
      let proposal = candidate.proposal
      let current: CoreAgentSkill
      if let simulated = simulatedSkillsByID[proposal.skillID] {
        current = simulated
      } else if let stored = await store.currentSkill(id: proposal.skillID) {
        current = stored
      } else {
        throw CoreAgentSkillOptimizationError.missingSkill(proposal.skillID)
      }
      try validateSkillOptimizationScores(
        proposal.validation,
        baselineScore: proposal.baselineScore
      )
      if acceptedCount >= request.policy.maxAcceptedProposalsPerRun {
        continue
      }
      if proposal.candidateEdits.count > request.policy.maxEditsPerProposal {
        continue
      }
      if request.policy.trainingSuiteIDs.contains(proposal.validation.heldoutSuiteID) {
        continue
      }
      if editsProtectedRegion(
        proposal.candidateEdits,
        in: current.body,
        regions: request.policy.protectedRegions
      ) {
        continue
      }
      if editsExceedLimits(
        proposal.candidateEdits,
        body: current.body,
        limits: request.policy.editLimits
      ) {
        continue
      }
      let delta = proposal.validation.score - proposal.baselineScore
      guard proposal.validation.passed,
        proposal.validation.score > proposal.baselineScore,
        delta >= request.policy.minimumScoreDelta
      else {
        continue
      }
      let candidateBody = try applyEdits(
        proposal.candidateEdits,
        to: current.body,
        limits: request.policy.editLimits
      )
      simulatedSkillsByID[proposal.skillID] = CoreAgentSkill(
        id: current.id,
        version: current.version + 1,
        title: current.title,
        body: candidateBody,
        tags: current.tags,
        priority: current.priority,
        provenance: current.provenance
      )
      acceptedCount += 1
    }
  }

  private func validateUniqueProposalIDs(
    _ proposals: [CoreAgentSkillSleepOptimizationProposal]
  ) throws {
    var seen: Set<String> = []
    for proposal in proposals {
      guard seen.insert(proposal.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(proposal.id)
      }
    }
  }

  private func reject(
    _ candidate: CoreAgentSkillSleepOptimizationProposal,
    current: CoreAgentSkill,
    request: CoreAgentSkillSleepOptimizationRequest,
    reason: CoreAgentSkillOptimizationRejectionReason
  ) async throws -> CoreAgentSkillSleepOptimizationEntry {
    try await store.recordRejected(
      CoreAgentRejectedSkillEdit(
        edits: candidate.proposal.candidateEdits,
        validation: candidate.proposal.validation
      ),
      skillID: candidate.proposal.skillID
    )
    try await store.recordMetaObservation(
      CoreAgentSkillMetaObservation(
        runID: request.runID,
        proposalID: candidate.id,
        reason: reason,
        notes: candidate.proposal.validation.notes
      ),
      skillID: candidate.proposal.skillID
    )
    return CoreAgentSkillSleepOptimizationEntry(
      proposalID: candidate.id,
      skillID: candidate.proposal.skillID,
      decision: .rejected(reason),
      skillVersionBefore: current.version,
      skillVersionAfter: nil,
      baselineScore: candidate.proposal.baselineScore,
      validation: candidate.proposal.validation,
      evidenceIDs: candidate.evidence.map(\.id)
    )
  }

}

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

public struct CoreAgentSkillOptimizationRunHarvestConfig: Sendable {
  public let projectID: String
  public let threadID: String?
  public let maximumTotalTokens: Int?

  public init(
    projectID: String,
    threadID: String? = nil,
    maximumTotalTokens: Int? = nil
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.maximumTotalTokens = maximumTotalTokens.map { max(0, $0) }
  }
}

public struct CoreAgentSkillOptimizationRunReplayConfig: Sendable {
  public let generationPolicy: CoreAgentSkillReplayGenerationPolicy
  public let executionPolicy: CoreAgentSkillReplayExecutionPolicy
  public let backend: any CoreAgentSkillReplayBackend

  public init(
    generationPolicy: CoreAgentSkillReplayGenerationPolicy,
    executionPolicy: CoreAgentSkillReplayExecutionPolicy = CoreAgentSkillReplayExecutionPolicy(),
    backend: any CoreAgentSkillReplayBackend
  ) {
    self.generationPolicy = generationPolicy
    self.executionPolicy = executionPolicy
    self.backend = backend
  }
}

public struct CoreAgentSkillOptimizationRunProposalConfig: Sendable {
  public let backend: any CoreAgentSkillModelProposalBackend
  public let maxProposals: Int

  public init(
    backend: any CoreAgentSkillModelProposalBackend,
    maxProposals: Int = 3
  ) {
    self.backend = backend
    self.maxProposals = maxProposals
  }
}

public struct CoreAgentSkillMetaSkillRunConfig: Sendable {
  public let skillID: CoreAgentSkillID
  public let snapshot: CoreAgentSkillMetaSkillBranchSnapshot
  public let previousEpoch: Int

  public init(
    skillID: CoreAgentSkillID,
    snapshot: CoreAgentSkillMetaSkillBranchSnapshot,
    previousEpoch: Int
  ) {
    self.skillID = skillID
    self.snapshot = snapshot
    self.previousEpoch = previousEpoch
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierConfig: Sendable {
  public let scores: [CoreAgentSkillMetaEvolutionFrontierScore]
  public let policy: CoreAgentSkillMetaEvolutionFrontierPolicy

  public init(
    scores: [CoreAgentSkillMetaEvolutionFrontierScore],
    policy: CoreAgentSkillMetaEvolutionFrontierPolicy =
      CoreAgentSkillMetaEvolutionFrontierPolicy()
  ) {
    self.scores = scores
    self.policy = policy
  }
}

public struct CoreAgentSkillOptimizationRunTarget: Sendable {
  public let skillID: CoreAgentSkillID
  public let baselineScore: Double

  public init(skillID: CoreAgentSkillID, baselineScore: Double) {
    self.skillID = skillID
    self.baselineScore = baselineScore
  }
}

public struct CoreAgentSkillOptimizationRunRequest: Sendable {
  public let runID: String
  public let policy: CoreAgentSkillOptimizationPolicy
  public let harvest: CoreAgentSkillOptimizationRunHarvestConfig?
  public let replay: CoreAgentSkillOptimizationRunReplayConfig?
  public let proposal: CoreAgentSkillOptimizationRunProposalConfig?
  public let memory: CoreAgentSkillRSIMemoryImportConfig?
  public let metaSkill: CoreAgentSkillMetaSkillRunConfig?
  public let frontier: CoreAgentSkillMetaEvolutionFrontierConfig?
  public let targets: [CoreAgentSkillOptimizationRunTarget]
  public let seedEvidence: [CoreAgentSkillRolloutEvidence]
  public let suppliedProposals: [CoreAgentSkillSleepOptimizationProposal]

  public init(
    runID: String,
    policy: CoreAgentSkillOptimizationPolicy = CoreAgentSkillOptimizationPolicy(),
    harvest: CoreAgentSkillOptimizationRunHarvestConfig? = nil,
    replay: CoreAgentSkillOptimizationRunReplayConfig? = nil,
    proposal: CoreAgentSkillOptimizationRunProposalConfig? = nil,
    memory: CoreAgentSkillRSIMemoryImportConfig? = nil,
    metaSkill: CoreAgentSkillMetaSkillRunConfig? = nil,
    frontier: CoreAgentSkillMetaEvolutionFrontierConfig? = nil,
    targets: [CoreAgentSkillOptimizationRunTarget] = [],
    seedEvidence: [CoreAgentSkillRolloutEvidence] = [],
    suppliedProposals: [CoreAgentSkillSleepOptimizationProposal] = []
  ) {
    self.runID = runID
    self.policy = policy
    self.harvest = harvest
    self.replay = replay
    self.proposal = proposal
    self.memory = memory
    self.metaSkill = metaSkill
    self.frontier = frontier
    self.targets = targets
    self.seedEvidence = seedEvidence
    self.suppliedProposals = suppliedProposals
  }
}

public enum CoreAgentSkillOptimizationRunPhase: String, Codable, Equatable, Sendable {
  case metaSkillStateRecorded
  case harvested
  case replayGenerated
  case replayExecuted
  case proposalsGenerated
  case memoryImported
  case frontierSelected
  case sleepOptimized
  case metaSkillEvolved
}

public struct CoreAgentSkillOptimizationRunPhaseRecord: Equatable, Sendable {
  public let phase: CoreAgentSkillOptimizationRunPhase
  public let harvestedEvidenceCount: Int
  public let replayRequestCount: Int
  public let replayEvidenceCount: Int
  public let proposalCount: Int
  public let acceptedProposalCount: Int
  public let rejectedProposalCount: Int
  public let importedMemoryEntryCount: Int
  public let metaSkillEvolutionRecordCount: Int

  public init(
    phase: CoreAgentSkillOptimizationRunPhase,
    harvestedEvidenceCount: Int = 0,
    replayRequestCount: Int = 0,
    replayEvidenceCount: Int = 0,
    proposalCount: Int = 0,
    acceptedProposalCount: Int = 0,
    rejectedProposalCount: Int = 0,
    importedMemoryEntryCount: Int = 0,
    metaSkillEvolutionRecordCount: Int = 0
  ) {
    self.phase = phase
    self.harvestedEvidenceCount = harvestedEvidenceCount
    self.replayRequestCount = replayRequestCount
    self.replayEvidenceCount = replayEvidenceCount
    self.proposalCount = proposalCount
    self.acceptedProposalCount = acceptedProposalCount
    self.rejectedProposalCount = rejectedProposalCount
    self.importedMemoryEntryCount = importedMemoryEntryCount
    self.metaSkillEvolutionRecordCount = metaSkillEvolutionRecordCount
  }
}

public struct CoreAgentSkillOptimizationRunReport: Equatable, Sendable {
  public let runID: String
  public let seedEvidenceIDs: [String]
  public let harvestedEvidenceIDs: [String]
  public let replayRequestIDs: [String]
  public let replayEvidenceIDs: [String]
  public let generatedProposalIDs: [String]
  public let suppliedProposalIDs: [String]
  public let importedMemoryEntryIDs: [String]
  public let frontierSelectedProposalIDs: [String]
  public let frontierRejectedProposalIDs: [String]
  public let metaSkillBranchID: String?
  public let metaSkillEpoch: Int?
  public let metaSkillEvolutionRecordCount: Int
  public let sleepReport: CoreAgentSkillSleepOptimizationReport?
  public let phases: [CoreAgentSkillOptimizationRunPhaseRecord]

  public init(
    runID: String,
    seedEvidenceIDs: [String],
    harvestedEvidenceIDs: [String],
    replayRequestIDs: [String],
    replayEvidenceIDs: [String],
    generatedProposalIDs: [String],
    suppliedProposalIDs: [String],
    importedMemoryEntryIDs: [String] = [],
    frontierSelectedProposalIDs: [String] = [],
    frontierRejectedProposalIDs: [String] = [],
    metaSkillBranchID: String? = nil,
    metaSkillEpoch: Int? = nil,
    metaSkillEvolutionRecordCount: Int = 0,
    sleepReport: CoreAgentSkillSleepOptimizationReport?,
    phases: [CoreAgentSkillOptimizationRunPhaseRecord]
  ) {
    self.runID = runID
    self.seedEvidenceIDs = seedEvidenceIDs
    self.harvestedEvidenceIDs = harvestedEvidenceIDs
    self.replayRequestIDs = replayRequestIDs
    self.replayEvidenceIDs = replayEvidenceIDs
    self.generatedProposalIDs = generatedProposalIDs
    self.suppliedProposalIDs = suppliedProposalIDs
    self.importedMemoryEntryIDs = importedMemoryEntryIDs
    self.frontierSelectedProposalIDs = frontierSelectedProposalIDs
    self.frontierRejectedProposalIDs = frontierRejectedProposalIDs
    self.metaSkillBranchID = metaSkillBranchID
    self.metaSkillEpoch = metaSkillEpoch
    self.metaSkillEvolutionRecordCount = metaSkillEvolutionRecordCount
    self.sleepReport = sleepReport
    self.phases = phases
  }

  public var uniqueEvidenceCount: Int {
    Set(seedEvidenceIDs + harvestedEvidenceIDs + replayEvidenceIDs).count
  }
}

public struct CoreAgentSkillOptimizationRunExecutor: Sendable {
  private let store: any CoreAgentSkillStore
  private let engineStore: (any CoreAgentEngineStore)?

  public init(
    store: any CoreAgentSkillStore,
    engineStore: (any CoreAgentEngineStore)? = nil
  ) {
    self.store = store
    self.engineStore = engineStore
  }

  public func run(
    _ request: CoreAgentSkillOptimizationRunRequest
  ) async throws -> CoreAgentSkillOptimizationRunReport {
    try Self.validate(request, engineStoreConfigured: engineStore != nil)
    try request.policy.validate()

    if let memory = request.memory {
      guard await store.currentSkill(id: memory.skillID) != nil else {
        throw CoreAgentSkillOptimizationError.missingSkill(memory.skillID)
      }
    }
    if let metaSkill = request.metaSkill {
      guard await store.currentSkill(id: metaSkill.skillID) != nil else {
        throw CoreAgentSkillOptimizationError.missingSkill(metaSkill.skillID)
      }
      guard metaSkill.snapshot.epoch > metaSkill.previousEpoch else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "meta-skill evolution epoch must advance"
        )
      }
    }

    var phases: [CoreAgentSkillOptimizationRunPhaseRecord] = []
    var evidence = try Self.dedupedEvidence(request.seedEvidence)
    let seedEvidenceIDs = evidence.map(\.id)
    var metaSkillBranchID: String?
    var metaSkillEpoch: Int?
    var metaSkillEvolutionRecordCount = 0

    if let metaSkill = request.metaSkill {
      try await store.recordMetaSkillSnapshot(metaSkill.snapshot, skillID: metaSkill.skillID)
      metaSkillBranchID = metaSkill.snapshot.branchID
      metaSkillEpoch = metaSkill.snapshot.epoch
      phases.append(CoreAgentSkillOptimizationRunPhaseRecord(phase: .metaSkillStateRecorded))
    }

    var harvestedIDs: [String] = []
    if let harvest = request.harvest {
      guard let engineStore else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "harvest config requires engineStore on executor"
        )
      }
      let harvester = CoreAgentSkillEngineTraceHarvester(engineStore: engineStore)
      let harvested = await harvester.harvest(
        projectID: harvest.projectID,
        threadID: harvest.threadID
      )
      if let maximumTotalTokens = harvest.maximumTotalTokens {
        let harvestableTraces = await engineStore.traces(
          projectID: harvest.projectID,
          threadID: harvest.threadID
        )
        let harvestedTokenUsage = CoreAgentSkillEngineTraceHarvester.totalTokenUsage(
          in: harvestableTraces
        )
        guard harvestedTokenUsage <= maximumTotalTokens else {
          throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
            "harvested Engine trace token usage \(harvestedTokenUsage) exceeds maximumTotalTokens \(maximumTotalTokens)"
          )
        }
      }
      harvestedIDs = harvested.map(\.id)
      evidence = try Self.mergedEvidence(evidence, harvested)
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .harvested,
          harvestedEvidenceCount: harvested.count
        )
      )
    }

    var replayRequestIDs: [String] = []
    var replayEvidenceIDs: [String] = []
    if let replay = request.replay {
      let generator = CoreAgentSkillReplayGenerator()
      let replayRequests = try generator.generate(from: evidence, policy: replay.generationPolicy)
      replayRequestIDs = replayRequests.map(\.id)
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .replayGenerated,
          replayRequestCount: replayRequests.count
        )
      )
      if !replayRequests.isEmpty {
        let executor = CoreAgentSkillReplayExecutor(
          backend: replay.backend,
          policy: replay.executionPolicy
        )
        let replayEvidence = try await executor.execute(replayRequests)
        replayEvidenceIDs = replayEvidence.map(\.id)
        evidence = try Self.mergedEvidence(evidence, replayEvidence)
        phases.append(
          CoreAgentSkillOptimizationRunPhaseRecord(
            phase: .replayExecuted,
            replayEvidenceCount: replayEvidence.count
          )
        )
      }
    }

    var importedMemoryEntryIDs: [String] = []
    if let memory = request.memory {
      let evidenceDigestKeys = evidence.flatMap { [$0.transcriptDigest, $0.toolEventDigest] }
      let references = try await memory.adapter.fetchReferences(
        CoreAgentSkillRSIMemoryFetchRequest(
          runID: request.runID,
          skillID: memory.skillID,
          evidenceDigestKeys: evidenceDigestKeys,
          maxEntries: memory.maxEntries
        )
      )
      let importReport = try await CoreAgentSkillRSIMemoryImporter(store: store).importReferences(
        references,
        runID: request.runID,
        skillID: memory.skillID
      )
      importedMemoryEntryIDs = importReport.importedEntryIDs
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .memoryImported,
          importedMemoryEntryCount: importReport.importedEntryIDs.count
        )
      )
    }

    var generatedProposalIDs: [String] = []
    var allProposals = request.suppliedProposals
    if let proposal = request.proposal {
      let generator = CoreAgentSkillModelProposalGenerator(backend: proposal.backend)
      for target in request.targets {
        guard let skill = await store.currentSkill(id: target.skillID) else {
          throw CoreAgentSkillOptimizationError.missingSkill(target.skillID)
        }
        let generated = try await generator.generate(
          runID: request.runID,
          skill: skill,
          baselineScore: target.baselineScore,
          evidence: evidence,
          policy: request.policy,
          maxProposals: proposal.maxProposals
        )
        generatedProposalIDs.append(contentsOf: generated.map(\.id))
        allProposals.append(contentsOf: generated)
      }
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .proposalsGenerated,
          proposalCount: generatedProposalIDs.count
        )
      )
    }

    let suppliedProposalIDs = request.suppliedProposals.map(\.id)
    var frontierSelectedProposalIDs: [String] = []
    var frontierRejectedProposalIDs: [String] = []
    if let frontier = request.frontier {
      let selection = try CoreAgentSkillMetaEvolutionFrontierSelector().select(
        proposals: allProposals,
        scores: frontier.scores,
        policy: frontier.policy
      )
      frontierSelectedProposalIDs = selection.selected.map(\.id)
      frontierRejectedProposalIDs = selection.rejectedProposalIDs
      allProposals = selection.selected
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .frontierSelected,
          proposalCount: frontierSelectedProposalIDs.count,
          rejectedProposalCount: frontierRejectedProposalIDs.count
        )
      )
    }
    var sleepReport: CoreAgentSkillSleepOptimizationReport?
    if !allProposals.isEmpty {
      sleepReport = try await CoreAgentSkillSleepOptimizer(store: store).run(
        CoreAgentSkillSleepOptimizationRequest(
          runID: request.runID,
          proposals: allProposals,
          policy: request.policy
        )
      )
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .sleepOptimized,
          proposalCount: allProposals.count,
          acceptedProposalCount: sleepReport?.acceptedCount ?? 0,
          rejectedProposalCount: sleepReport?.rejectedCount ?? 0
        )
      )
    }
    if let metaSkill = request.metaSkill, let sleepReport {
      let sleepAcceptedProposalIDs = sleepReport.entries.compactMap { entry -> String? in
        entry.decision == .accepted ? entry.proposalID : nil
      }
      let sleepRejectedProposalIDs = sleepReport.entries.compactMap { entry -> String? in
        if case .rejected = entry.decision {
          return entry.proposalID
        }
        return nil
      }
      let rejectedProposalIDs = orderedUnique(
        frontierRejectedProposalIDs + sleepRejectedProposalIDs
      )
      try await store.recordMetaSkillEvolution(
        CoreAgentSkillMetaSkillEvolutionRecord(
          runID: request.runID,
          branchID: metaSkill.snapshot.branchID,
          previousEpoch: metaSkill.previousEpoch,
          nextEpoch: metaSkill.snapshot.epoch,
          acceptedProposalIDs: sleepAcceptedProposalIDs,
          rejectedProposalIDs: rejectedProposalIDs,
          frontierRejectedProposalIDs: frontierRejectedProposalIDs,
          sleepAcceptedProposalIDs: sleepAcceptedProposalIDs,
          sleepRejectedProposalIDs: sleepRejectedProposalIDs,
          evidenceDigest: Self.metaSkillEvolutionEvidenceDigest(
            runID: request.runID,
            branchID: metaSkill.snapshot.branchID,
            previousEpoch: metaSkill.previousEpoch,
            nextEpoch: metaSkill.snapshot.epoch,
            frontierRejectedProposalIDs: frontierRejectedProposalIDs,
            sleepAcceptedProposalIDs: sleepAcceptedProposalIDs,
            sleepRejectedProposalIDs: sleepRejectedProposalIDs
          )
        ),
        skillID: metaSkill.skillID
      )
      metaSkillEvolutionRecordCount = 1
      phases.append(
        CoreAgentSkillOptimizationRunPhaseRecord(
          phase: .metaSkillEvolved,
          acceptedProposalCount: sleepAcceptedProposalIDs.count,
          rejectedProposalCount: rejectedProposalIDs.count,
          metaSkillEvolutionRecordCount: 1
        )
      )
    }

    return CoreAgentSkillOptimizationRunReport(
      runID: request.runID,
      seedEvidenceIDs: seedEvidenceIDs,
      harvestedEvidenceIDs: harvestedIDs,
      replayRequestIDs: replayRequestIDs,
      replayEvidenceIDs: replayEvidenceIDs,
      generatedProposalIDs: generatedProposalIDs,
      suppliedProposalIDs: suppliedProposalIDs,
      importedMemoryEntryIDs: importedMemoryEntryIDs,
      frontierSelectedProposalIDs: frontierSelectedProposalIDs,
      frontierRejectedProposalIDs: frontierRejectedProposalIDs,
      metaSkillBranchID: metaSkillBranchID,
      metaSkillEpoch: metaSkillEpoch,
      metaSkillEvolutionRecordCount: metaSkillEvolutionRecordCount,
      sleepReport: sleepReport,
      phases: phases
    )
  }

  private static func validate(
    _ request: CoreAgentSkillOptimizationRunRequest,
    engineStoreConfigured: Bool
  ) throws {
    guard !request.runID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "optimization run ID must be non-empty"
      )
    }
    if request.harvest != nil, !engineStoreConfigured {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "harvest config requires engineStore on executor"
      )
    }
    if request.proposal != nil, request.targets.isEmpty {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "proposal generation requires at least one optimization target"
      )
    }
    if let metaSkill = request.metaSkill, metaSkill.previousEpoch < 0 {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "meta-skill evolution previous epoch must be non-negative"
      )
    }
    for target in request.targets {
      guard target.baselineScore.isFinite,
        target.baselineScore >= 0,
        target.baselineScore <= 1
      else {
        throw CoreAgentSkillOptimizationError.invalidValidationScore(target.baselineScore)
      }
    }
    _ = try dedupedEvidence(request.seedEvidence)
    var seenProposalIDs: Set<String> = []
    for proposal in request.suppliedProposals {
      guard seenProposalIDs.insert(proposal.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(proposal.id)
      }
    }
  }

  private static func metaSkillEvolutionEvidenceDigest(
    runID: String,
    branchID: String,
    previousEpoch: Int,
    nextEpoch: Int,
    frontierRejectedProposalIDs: [String],
    sleepAcceptedProposalIDs: [String],
    sleepRejectedProposalIDs: [String]
  ) -> String {
    let payload = [
      "run=\(runID)",
      "branch=\(branchID)",
      "previous=\(previousEpoch)",
      "next=\(nextEpoch)",
      "frontierRejected=\(frontierRejectedProposalIDs.joined(separator: ","))",
      "sleepAccepted=\(sleepAcceptedProposalIDs.joined(separator: ","))",
      "sleepRejected=\(sleepRejectedProposalIDs.joined(separator: ","))",
    ].joined(separator: "\n")
    return "sha256:\(sha256Hex(Data(payload.utf8)))"
  }

  private static func dedupedEvidence(
    _ evidence: [CoreAgentSkillRolloutEvidence]
  ) throws -> [CoreAgentSkillRolloutEvidence] {
    var seen: Set<String> = []
    var result: [CoreAgentSkillRolloutEvidence] = []
    for item in evidence {
      guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "evidence ID must be non-empty"
        )
      }
      guard seen.insert(item.id).inserted else { continue }
      result.append(item)
    }
    return result
  }

  private static func mergedEvidence(
    _ existing: [CoreAgentSkillRolloutEvidence],
    _ incoming: [CoreAgentSkillRolloutEvidence]
  ) throws -> [CoreAgentSkillRolloutEvidence] {
    var seen = Set(existing.map(\.id))
    var merged = existing
    for item in incoming {
      guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "evidence ID must be non-empty"
        )
      }
      guard seen.insert(item.id).inserted else { continue }
      merged.append(item)
    }
    return merged
  }
}

private func editsExceedLimits(
  _ edits: [CoreAgentSkillEdit],
  body: String,
  limits: CoreAgentSkillEditLimits
) -> Bool {
  do {
    _ = try applyEdits(edits, to: body, limits: limits)
    return false
  } catch CoreAgentSkillOptimizationError.editTooLarge,
    CoreAgentSkillOptimizationError.resultingSkillTooLarge
  {
    return true
  } catch {
    return false
  }
}

private func applyEdits(
  _ edits: [CoreAgentSkillEdit],
  to body: String,
  limits: CoreAgentSkillEditLimits
) throws -> String {
  var candidateBody = body
  for edit in edits {
    candidateBody = try edit.apply(to: candidateBody, limits: limits)
  }
  return candidateBody
}

private func validateSkillOptimizationScores(
  _ validation: CoreAgentSkillValidationResult,
  baselineScore: Double
) throws {
  guard baselineScore.isFinite,
    baselineScore >= 0,
    baselineScore <= 1,
    validation.score.isFinite,
    validation.score >= 0,
    validation.score <= 1
  else {
    throw CoreAgentSkillOptimizationError.invalidValidationScore(validation.score)
  }
  guard !validation.heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  else {
    throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
  }
}

private func editsProtectedRegion(
  _ edits: [CoreAgentSkillEdit],
  in body: String,
  regions: [CoreAgentSkillProtectedRegion]
) -> Bool {
  guard !regions.isEmpty else { return false }
  let protectedRanges = regions.flatMap { protectedRanges(for: $0, in: body) }
  guard !protectedRanges.isEmpty else { return false }
  for edit in edits {
    switch edit {
    case .append:
      if protectedRanges.contains(where: \.isOpenEnded) {
        return true
      }
    case .replace(let target, _):
      guard let targetRange = body.range(of: target) else {
        continue
      }
      if protectedRanges.contains(where: { $0.range.overlaps(targetRange) }) {
        return true
      }
    }
  }
  return false
}

private struct CoreAgentProtectedSkillRange {
  let range: Range<String.Index>
  let isOpenEnded: Bool
}

private func protectedRanges(
  for region: CoreAgentSkillProtectedRegion,
  in body: String
) -> [CoreAgentProtectedSkillRange] {
  guard !region.startMarker.isEmpty, !region.endMarker.isEmpty else {
    return []
  }
  var ranges: [CoreAgentProtectedSkillRange] = []
  var searchStart = body.startIndex
  while searchStart < body.endIndex,
    let start = body.range(of: region.startMarker, range: searchStart..<body.endIndex)
  {
    guard let end = body.range(of: region.endMarker, range: start.upperBound..<body.endIndex)
    else {
      ranges.append(
        CoreAgentProtectedSkillRange(
          range: start.lowerBound..<body.endIndex,
          isOpenEnded: true
        )
      )
      return ranges
    }
    ranges.append(
      CoreAgentProtectedSkillRange(
        range: start.lowerBound..<end.upperBound,
        isOpenEnded: false
      )
    )
    searchStart = end.upperBound
  }
  return ranges
}

public enum CoreAgentSkillExporter {
  public static func bestSkillMarkdown(_ skill: CoreAgentSkill) -> String {
    var lines: [String] = [
      "# \(skill.title)",
      "",
      "Version: \(skill.version)",
      "Tags: \(skill.tags.joined(separator: ", "))",
      "",
      skill.body,
    ]
    if let latest = skill.provenance.last {
      lines.append("")
      lines.append("Heldout Suite: \(latest.heldoutSuiteID)")
      lines.append("Validation Score: \(latest.validationScore)")
    }
    return lines.joined(separator: "\n")
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierPolicy:
  Codable, Equatable, Sendable
{
  public let maxSelectedProposals: Int
  public let productivityWeight: Double
  public let noveltyWeight: Double
  public let strictScoreWeight: Double
  public let looseScoreWeight: Double
  public let minimumNoveltyScore: Double?
  public let maximumHackRatio: Double?

  public init(
    maxSelectedProposals: Int = 1,
    productivityWeight: Double = 0.45,
    noveltyWeight: Double = 0.25,
    strictScoreWeight: Double = 0.10,
    looseScoreWeight: Double = 0.20,
    minimumNoveltyScore: Double? = nil,
    maximumHackRatio: Double? = nil
  ) {
    self.maxSelectedProposals = maxSelectedProposals
    self.productivityWeight = productivityWeight
    self.noveltyWeight = noveltyWeight
    self.strictScoreWeight = strictScoreWeight
    self.looseScoreWeight = looseScoreWeight
    self.minimumNoveltyScore = minimumNoveltyScore
    self.maximumHackRatio = maximumHackRatio
  }

  fileprivate func validate() throws {
    guard maxSelectedProposals > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "frontier maxSelectedProposals must be positive"
      )
    }
    let weights = [
      productivityWeight,
      noveltyWeight,
      strictScoreWeight,
      looseScoreWeight,
    ]
    guard weights.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "frontier weights must be finite and non-negative"
      )
    }
    guard weights.reduce(0, +) > 0 else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "frontier weights must not all be zero"
      )
    }
    if let minimumNoveltyScore {
      try validateMetaEvolutionUnitScore(
        minimumNoveltyScore,
        field: "minimumNoveltyScore"
      )
    }
    if let maximumHackRatio {
      guard maximumHackRatio.isFinite, maximumHackRatio > 0 else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier maximumHackRatio must be finite and positive"
        )
      }
    }
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierScore:
  Codable, Equatable, Sendable
{
  public let proposalID: String
  public let productivityScore: Double
  public let noveltyScore: Double
  public let strictScore: Double
  public let looseScore: Double
  public let objectiveEvaluations: [CoreAgentHarnessObjectiveEvaluation]

  public init(
    proposalID: String,
    productivityScore: Double,
    noveltyScore: Double,
    strictScore: Double,
    looseScore: Double,
    objectiveEvaluations: [CoreAgentHarnessObjectiveEvaluation] = []
  ) {
    self.proposalID = proposalID
    self.productivityScore = productivityScore
    self.noveltyScore = noveltyScore
    self.strictScore = strictScore
    self.looseScore = looseScore
    self.objectiveEvaluations = objectiveEvaluations
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierAuditEntry:
  Equatable, Sendable
{
  public let proposalID: String
  public let weightedScore: Double
  public let productivityScore: Double
  public let noveltyScore: Double
  public let strictScore: Double
  public let looseScore: Double
  public let hackRatio: Double
  public let eligible: Bool

  public init(
    proposalID: String,
    weightedScore: Double,
    productivityScore: Double,
    noveltyScore: Double,
    strictScore: Double,
    looseScore: Double,
    hackRatio: Double,
    eligible: Bool
  ) {
    self.proposalID = proposalID
    self.weightedScore = weightedScore
    self.productivityScore = productivityScore
    self.noveltyScore = noveltyScore
    self.strictScore = strictScore
    self.looseScore = looseScore
    self.hackRatio = hackRatio
    self.eligible = eligible
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierSelection:
  Sendable
{
  public let selected: [CoreAgentSkillSleepOptimizationProposal]
  public let rejectedProposalIDs: [String]
  public let auditTrail: [CoreAgentSkillMetaEvolutionFrontierAuditEntry]

  public init(
    selected: [CoreAgentSkillSleepOptimizationProposal],
    rejectedProposalIDs: [String],
    auditTrail: [CoreAgentSkillMetaEvolutionFrontierAuditEntry]
  ) {
    self.selected = selected
    self.rejectedProposalIDs = rejectedProposalIDs
    self.auditTrail = auditTrail
  }
}

public struct CoreAgentSkillMetaEvolutionFrontierSelector: Sendable {
  public init() {}

  public func select(
    proposals: [CoreAgentSkillSleepOptimizationProposal],
    scores: [CoreAgentSkillMetaEvolutionFrontierScore],
    policy: CoreAgentSkillMetaEvolutionFrontierPolicy =
      CoreAgentSkillMetaEvolutionFrontierPolicy()
  ) throws -> CoreAgentSkillMetaEvolutionFrontierSelection {
    try policy.validate()
    try validateUniqueFrontierProposals(proposals)
    let scoreByProposalID = try validateFrontierScores(scores, proposals: proposals)

    let proposalByID = Dictionary(uniqueKeysWithValues: proposals.map { ($0.id, $0) })
    var audit: [CoreAgentSkillMetaEvolutionFrontierAuditEntry] = []
    for proposal in proposals {
      guard let score = scoreByProposalID[proposal.id] else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier score missing for proposal \(proposal.id)"
        )
      }
      audit.append(entry(for: score, policy: policy))
    }
    audit.sort { lhs, rhs in
      if lhs.weightedScore != rhs.weightedScore {
        return lhs.weightedScore > rhs.weightedScore
      }
      return lhs.proposalID < rhs.proposalID
    }

    let selectedIDs = Array(audit.filter(\.eligible).prefix(policy.maxSelectedProposals))
      .map(\.proposalID)
    let selected = selectedIDs.compactMap { proposalByID[$0] }
    let selectedIDSet = Set(selectedIDs)
    let rejectedProposalIDs = audit.map(\.proposalID).filter {
      !selectedIDSet.contains($0)
    }

    return CoreAgentSkillMetaEvolutionFrontierSelection(
      selected: selected,
      rejectedProposalIDs: rejectedProposalIDs,
      auditTrail: audit
    )
  }

  private func entry(
    for score: CoreAgentSkillMetaEvolutionFrontierScore,
    policy: CoreAgentSkillMetaEvolutionFrontierPolicy
  ) -> CoreAgentSkillMetaEvolutionFrontierAuditEntry {
    let hackRatio = score.looseScore / max(score.strictScore, 0.0001)
    let weightedScore =
      (score.productivityScore * policy.productivityWeight)
      + (score.noveltyScore * policy.noveltyWeight)
      + (score.strictScore * policy.strictScoreWeight)
      + (score.looseScore * policy.looseScoreWeight)
    let passesNovelty =
      policy.minimumNoveltyScore.map {
        score.noveltyScore >= $0
      } ?? true
    let passesHackRatio =
      policy.maximumHackRatio.map {
        hackRatio <= $0
      } ?? true

    return CoreAgentSkillMetaEvolutionFrontierAuditEntry(
      proposalID: score.proposalID,
      weightedScore: weightedScore,
      productivityScore: score.productivityScore,
      noveltyScore: score.noveltyScore,
      strictScore: score.strictScore,
      looseScore: score.looseScore,
      hackRatio: hackRatio,
      eligible: passesNovelty && passesHackRatio
    )
  }

  private func validateUniqueFrontierProposals(
    _ proposals: [CoreAgentSkillSleepOptimizationProposal]
  ) throws {
    var seenProposalIDs: Set<String> = []
    for proposal in proposals {
      guard isSafeProposalIdentifier(proposal.id) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier proposal ID is invalid"
        )
      }
      guard seenProposalIDs.insert(proposal.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(proposal.id)
      }
    }
  }

  private func validateFrontierScores(
    _ scores: [CoreAgentSkillMetaEvolutionFrontierScore],
    proposals: [CoreAgentSkillSleepOptimizationProposal]
  ) throws -> [String: CoreAgentSkillMetaEvolutionFrontierScore] {
    let proposalIDs = Set(proposals.map(\.id))
    var scoreByProposalID: [String: CoreAgentSkillMetaEvolutionFrontierScore] = [:]
    for score in scores {
      guard isSafeProposalIdentifier(score.proposalID) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier score proposal ID is invalid"
        )
      }
      guard proposalIDs.contains(score.proposalID) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier score references unknown proposal \(score.proposalID)"
        )
      }
      guard scoreByProposalID[score.proposalID] == nil else {
        throw CoreAgentSkillOptimizationError.duplicateOptimizationProposal(
          score.proposalID
        )
      }
      try validateMetaEvolutionUnitScore(
        score.productivityScore,
        field: "productivityScore"
      )
      try validateMetaEvolutionUnitScore(score.noveltyScore, field: "noveltyScore")
      try validateMetaEvolutionUnitScore(score.strictScore, field: "strictScore")
      try validateMetaEvolutionUnitScore(score.looseScore, field: "looseScore")
      try validateFrontierObjectiveEvaluations(
        score.objectiveEvaluations,
        proposalID: score.proposalID
      )
      scoreByProposalID[score.proposalID] = score
    }
    return scoreByProposalID
  }

  private func validateFrontierObjectiveEvaluations(
    _ evaluations: [CoreAgentHarnessObjectiveEvaluation],
    proposalID: String
  ) throws {
    var seenEvaluations: Set<CoreAgentHarnessObjectiveEvaluationKey> = []
    for evaluation in evaluations {
      guard evaluation.candidateID == proposalID else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier objective evaluation candidate must match proposal"
        )
      }
      guard !evaluation.heldoutSuiteID.isEmpty else {
        throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
      }
      guard !evaluation.objectiveID.rawValue.isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "frontier objective ID must be non-empty"
        )
      }
      guard evaluation.score.isFinite, (0...1).contains(evaluation.score) else {
        throw CoreAgentSkillOptimizationError.invalidValidationScore(evaluation.score)
      }
      let key = CoreAgentHarnessObjectiveEvaluationKey(evaluation: evaluation)
      guard seenEvaluations.insert(key).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessObjectiveEvaluation(
          "\(evaluation.candidateID):\(evaluation.heldoutSuiteID):\(evaluation.objectiveID.rawValue)"
        )
      }
    }
  }
}

private func validateMetaEvolutionUnitScore(_ score: Double, field: String) throws {
  guard score.isFinite, (0...1).contains(score) else {
    throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
      "frontier \(field) must be finite and in 0...1"
    )
  }
}

public struct CoreAgentHarnessCandidate: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let parameters: [String: String]

  public init(id: String, parameters: [String: String]) {
    self.id = id
    self.parameters = parameters
  }
}

public struct CoreAgentHarnessEvaluation: Codable, Equatable, Sendable {
  public let candidateID: String
  public let heldoutSuiteID: String
  public let score: Double

  public init(candidateID: String, heldoutSuiteID: String, score: Double) {
    self.candidateID = candidateID
    self.heldoutSuiteID = heldoutSuiteID
    self.score = score
  }
}

public enum CoreAgentHarnessObjectiveDirection: String, Codable, Equatable, Sendable {
  case maximize
  case minimize
}

public struct CoreAgentHarnessObjectiveID:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral
{
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }
}

public struct CoreAgentHarnessObjective: Codable, Equatable, Sendable, Identifiable {
  public let id: CoreAgentHarnessObjectiveID
  public let weight: Double
  public let direction: CoreAgentHarnessObjectiveDirection
  public let requiredMeanScore: Double?

  public init(
    id: CoreAgentHarnessObjectiveID,
    weight: Double = 1,
    direction: CoreAgentHarnessObjectiveDirection = .maximize,
    requiredMeanScore: Double? = nil
  ) {
    self.id = id
    self.weight = weight
    self.direction = direction
    self.requiredMeanScore = requiredMeanScore
  }
}

public struct CoreAgentHarnessObjectiveEvaluation: Codable, Equatable, Sendable {
  public let candidateID: String
  public let heldoutSuiteID: String
  public let objectiveID: CoreAgentHarnessObjectiveID
  public let score: Double

  public init(
    candidateID: String,
    heldoutSuiteID: String,
    objectiveID: CoreAgentHarnessObjectiveID,
    score: Double
  ) {
    self.candidateID = candidateID
    self.heldoutSuiteID = heldoutSuiteID
    self.objectiveID = objectiveID
    self.score = score
  }
}

public struct CoreAgentHarnessAuditEntry: Equatable, Sendable {
  public let candidateID: String
  public let meanScore: Double
  public let heldoutSuiteIDs: [String]
}

public struct CoreAgentHarnessObjectiveScore: Equatable, Sendable {
  public let objectiveID: CoreAgentHarnessObjectiveID
  public let meanScore: Double
  public let normalizedMeanScore: Double
  public let weight: Double
  public let weightedScore: Double
  public let heldoutSuiteIDs: [String]
  public let passedRequiredMean: Bool
}

public struct CoreAgentHarnessMultiObjectiveAuditEntry: Equatable, Sendable {
  public let candidateID: String
  public let weightedScore: Double
  public let eligible: Bool
  public let heldoutSuiteIDs: [String]
  public let objectiveScores: [CoreAgentHarnessObjectiveScore]
}

public struct CoreAgentHarnessOptimizationResult: Equatable, Sendable {
  public let best: CoreAgentHarnessCandidate
  public let heldoutSuiteIDs: [String]
  public let auditTrail: [CoreAgentHarnessAuditEntry]
}

public struct CoreAgentHarnessMultiObjectiveOptimizationResult: Equatable, Sendable {
  public let best: CoreAgentHarnessCandidate
  public let objectives: [CoreAgentHarnessObjective]
  public let heldoutSuiteIDs: [String]
  public let auditTrail: [CoreAgentHarnessMultiObjectiveAuditEntry]
}

public struct CoreAgentHarnessOptimizer: Sendable {
  public init() {}

  public func selectBest(
    candidates: [CoreAgentHarnessCandidate],
    evaluations: [CoreAgentHarnessEvaluation]
  ) throws -> CoreAgentHarnessOptimizationResult {
    var seenCandidates: Set<String> = []
    for candidate in candidates {
      guard seenCandidates.insert(candidate.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessCandidate(candidate.id)
      }
    }
    let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    var audit: [CoreAgentHarnessAuditEntry] = []
    for candidate in candidates {
      let scores = evaluations.filter { $0.candidateID == candidate.id }
      guard !scores.isEmpty else {
        throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(candidate.id)
      }
      let meanScore = scores.map(\.score).reduce(0, +) / Double(scores.count)
      audit.append(
        CoreAgentHarnessAuditEntry(
          candidateID: candidate.id,
          meanScore: meanScore,
          heldoutSuiteIDs: Array(Set(scores.map(\.heldoutSuiteID))).sorted()
        )
      )
    }
    audit.sort { lhs, rhs in
      if lhs.meanScore != rhs.meanScore {
        return lhs.meanScore > rhs.meanScore
      }
      return lhs.candidateID < rhs.candidateID
    }
    guard let bestEntry = audit.first,
      let best = candidateByID[bestEntry.candidateID]
    else {
      throw CoreAgentSkillOptimizationError.missingHarnessEvaluation("all")
    }
    return CoreAgentHarnessOptimizationResult(
      best: best,
      heldoutSuiteIDs: Array(Set(evaluations.map(\.heldoutSuiteID))).sorted(),
      auditTrail: audit
    )
  }

  public func selectBest(
    candidates: [CoreAgentHarnessCandidate],
    objectiveEvaluations: [CoreAgentHarnessObjectiveEvaluation],
    objectives: [CoreAgentHarnessObjective]
  ) throws -> CoreAgentHarnessMultiObjectiveOptimizationResult {
    try validateUniqueCandidates(candidates)
    try validateObjectives(objectives)
    let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    let objectiveIDs = Set(objectives.map(\.id))
    try validateObjectiveEvaluations(
      objectiveEvaluations,
      candidateIDs: Set(candidateByID.keys),
      objectiveIDs: objectiveIDs
    )

    let totalWeight = objectives.map(\.weight).reduce(0, +)
    var audit: [CoreAgentHarnessMultiObjectiveAuditEntry] = []
    for candidate in candidates {
      var objectiveScores: [CoreAgentHarnessObjectiveScore] = []
      var heldoutSuiteIDs: Set<String> = []
      for objective in objectives {
        let evaluations = objectiveEvaluations.filter {
          $0.candidateID == candidate.id && $0.objectiveID == objective.id
        }
        guard !evaluations.isEmpty else {
          throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(
            "\(candidate.id):\(objective.id.rawValue)"
          )
        }
        let meanScore = evaluations.map(\.score).reduce(0, +) / Double(evaluations.count)
        let normalizedMeanScore: Double
        switch objective.direction {
        case .maximize:
          normalizedMeanScore = meanScore
        case .minimize:
          normalizedMeanScore = 1 - meanScore
        }
        let suites = Array(Set(evaluations.map(\.heldoutSuiteID))).sorted()
        heldoutSuiteIDs.formUnion(suites)
        let passedRequiredMean =
          objective.requiredMeanScore.map {
            normalizedMeanScore >= $0
          } ?? true
        objectiveScores.append(
          CoreAgentHarnessObjectiveScore(
            objectiveID: objective.id,
            meanScore: meanScore,
            normalizedMeanScore: normalizedMeanScore,
            weight: objective.weight,
            weightedScore: normalizedMeanScore * objective.weight,
            heldoutSuiteIDs: suites,
            passedRequiredMean: passedRequiredMean
          )
        )
      }
      let weightedScore = objectiveScores.map(\.weightedScore).reduce(0, +) / totalWeight
      audit.append(
        CoreAgentHarnessMultiObjectiveAuditEntry(
          candidateID: candidate.id,
          weightedScore: weightedScore,
          eligible: objectiveScores.allSatisfy(\.passedRequiredMean),
          heldoutSuiteIDs: Array(heldoutSuiteIDs).sorted(),
          objectiveScores: objectiveScores
        )
      )
    }
    audit.sort { lhs, rhs in
      if lhs.eligible != rhs.eligible {
        return lhs.eligible && !rhs.eligible
      }
      if lhs.weightedScore != rhs.weightedScore {
        return lhs.weightedScore > rhs.weightedScore
      }
      return lhs.candidateID < rhs.candidateID
    }
    guard let bestEntry = audit.first(where: \.eligible),
      let best = candidateByID[bestEntry.candidateID]
    else {
      throw CoreAgentSkillOptimizationError.noEligibleHarnessCandidate
    }
    return CoreAgentHarnessMultiObjectiveOptimizationResult(
      best: best,
      objectives: objectives,
      heldoutSuiteIDs: Array(Set(objectiveEvaluations.map(\.heldoutSuiteID))).sorted(),
      auditTrail: audit
    )
  }

  private func validateUniqueCandidates(_ candidates: [CoreAgentHarnessCandidate]) throws {
    var seenCandidates: Set<String> = []
    for candidate in candidates {
      guard seenCandidates.insert(candidate.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessCandidate(candidate.id)
      }
    }
  }

  private func validateObjectives(_ objectives: [CoreAgentHarnessObjective]) throws {
    guard !objectives.isEmpty else {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "at least one objective is required"
      )
    }
    var seenObjectives: Set<CoreAgentHarnessObjectiveID> = []
    for objective in objectives {
      guard !objective.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "objective id must be non-empty"
        )
      }
      guard seenObjectives.insert(objective.id).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessObjective(objective.id)
      }
      guard objective.weight.isFinite, objective.weight > 0 else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "objective weight must be finite and positive"
        )
      }
      if let requiredMeanScore = objective.requiredMeanScore {
        guard requiredMeanScore.isFinite,
          requiredMeanScore >= 0,
          requiredMeanScore <= 1
        else {
          throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
            "required objective mean score must be between 0 and 1"
          )
        }
      }
    }
  }

  private func validateObjectiveEvaluations(
    _ evaluations: [CoreAgentHarnessObjectiveEvaluation],
    candidateIDs: Set<String>,
    objectiveIDs: Set<CoreAgentHarnessObjectiveID>
  ) throws {
    var seenEvaluations: Set<CoreAgentHarnessObjectiveEvaluationKey> = []
    for evaluation in evaluations {
      guard candidateIDs.contains(evaluation.candidateID) else {
        throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(evaluation.candidateID)
      }
      guard objectiveIDs.contains(evaluation.objectiveID) else {
        throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
          "unknown objective \(evaluation.objectiveID.rawValue)"
        )
      }
      guard !evaluation.heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
      }
      guard evaluation.score.isFinite, evaluation.score >= 0, evaluation.score <= 1 else {
        throw CoreAgentSkillOptimizationError.invalidValidationScore(evaluation.score)
      }
      let evaluationKey = CoreAgentHarnessObjectiveEvaluationKey(evaluation: evaluation)
      guard seenEvaluations.insert(evaluationKey).inserted else {
        throw CoreAgentSkillOptimizationError.duplicateHarnessObjectiveEvaluation(
          evaluationKey.stableDescription
        )
      }
    }
  }
}

private struct CoreAgentHarnessObjectiveEvaluationKey: Hashable {
  let candidateID: String
  let heldoutSuiteID: String
  let objectiveID: CoreAgentHarnessObjectiveID

  init(evaluation: CoreAgentHarnessObjectiveEvaluation) {
    self.candidateID = evaluation.candidateID
    self.heldoutSuiteID = evaluation.heldoutSuiteID
    self.objectiveID = evaluation.objectiveID
  }

  var stableDescription: String {
    [
      candidateID,
      heldoutSuiteID,
      objectiveID.rawValue,
    ].joined(separator: ":")
  }
}

public struct CoreAgentSkillMultiObjectiveValidationAdapter: Sendable {
  private let optimizer: CoreAgentHarnessOptimizer

  public init(optimizer: CoreAgentHarnessOptimizer = CoreAgentHarnessOptimizer()) {
    self.optimizer = optimizer
  }

  public func validationResult(
    candidateID: String,
    evaluations: [CoreAgentHarnessObjectiveEvaluation],
    objectives: [CoreAgentHarnessObjective],
    heldoutSuiteID: String,
    passingScore: Double = 0,
    notes: String = ""
  ) throws -> CoreAgentSkillValidationResult {
    guard !heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
    }
    guard passingScore.isFinite, passingScore >= 0, passingScore <= 1 else {
      throw CoreAgentSkillOptimizationError.invalidValidationScore(passingScore)
    }
    for evaluation in evaluations {
      guard !evaluation.heldoutSuiteID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw CoreAgentSkillOptimizationError.emptyHeldoutSuiteID
      }
    }
    let evaluationSuiteIDs = Set(evaluations.map(\.heldoutSuiteID))
    if !evaluationSuiteIDs.isEmpty, evaluationSuiteIDs != Set([heldoutSuiteID]) {
      throw CoreAgentSkillOptimizationError.invalidOptimizationPolicy(
        "adapter heldoutSuiteID must match objective evaluation suites"
      )
    }
    let result = try optimizer.selectBest(
      candidates: [CoreAgentHarnessCandidate(id: candidateID, parameters: [:])],
      objectiveEvaluations: evaluations,
      objectives: objectives
    )
    guard let entry = result.auditTrail.first else {
      throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(candidateID)
    }
    return CoreAgentSkillValidationResult(
      score: entry.weightedScore,
      heldoutSuiteID: heldoutSuiteID,
      passed: entry.eligible && entry.weightedScore >= passingScore,
      notes: notes
    )
  }
}

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sanitizedModelProposalEvidenceMetadata(
  _ metadata: [String: String]
) -> [String: String] {
  metadata.reduce(into: [:]) { result, pair in
    if modelProposalAllowedEvidenceMetadataKeys.contains(pair.key) {
      result[pair.key] =
        pair.key == "source_suite_id"
        ? pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
        : pair.value
    }
  }
}

private let modelProposalAllowedEvidenceMetadataKeys: Set<String> = [
  "source",
  "project_id",
  "thread_id",
  "run_id",
  "run_status",
  "event_count",
  "tool_event_count",
  "receipt_root_hash",
  "input_tokens",
  "cached_input_tokens",
  "output_tokens",
  "reasoning_tokens",
  "issue_id_digest",
  "issue_status",
  "suite_id",
  "replay_request_id",
  "replay_mode",
  "source_evidence_id",
  "source_transcript_digest",
  "source_tool_event_digest",
  "verifier_feedback_digest",
  "source_project_id",
  "source_thread_id",
  "source_run_id",
  "source_run_status",
  "source_issue_id_digest",
  "source_issue_status",
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

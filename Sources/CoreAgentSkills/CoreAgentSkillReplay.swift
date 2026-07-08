import CryptoKit
import Foundation

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

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func isSHA256Digest(_ value: String) -> Bool {
  guard value.hasPrefix("sha256:") else { return false }
  let hex = value.dropFirst("sha256:".count)
  guard hex.count == 64 else { return false }
  return hex.unicodeScalars.allSatisfy { scalar in
    (48...57).contains(Int(scalar.value)) || (97...102).contains(Int(scalar.value))
  }
}

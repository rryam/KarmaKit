import CoreAgent
import Foundation
import FoundationModels

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

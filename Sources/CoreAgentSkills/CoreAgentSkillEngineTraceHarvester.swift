import CoreAgent
import CoreAgentEngine
import CryptoKit
import Foundation

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

private func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

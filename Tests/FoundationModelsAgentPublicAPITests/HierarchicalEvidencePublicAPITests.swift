import Foundation
import FoundationModelsAgent
import Testing

private let publicEvidenceStart = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Hierarchical evidence public API consumer")
struct HierarchicalEvidencePublicAPITests {
  @Test("Deterministic root and child evidence links canonical run records")
  func deterministicLineageAndAttachments() throws {
    let root = AgentRunLineage.root(
      runID: AgentRunID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
      )
    )
    let child = try root.descendant(
      runID: AgentRunID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
      ),
      taskID: AgentTaskID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
      )
    )
    let routeEvent = publicEvent(
      id: "00000000-0000-0000-0000-000000000011",
      lineage: child,
      kind: .routeSelected
    )
    let contextEvent = publicEvent(
      id: "00000000-0000-0000-0000-000000000012",
      lineage: child,
      kind: .contextBudgetEvaluated
    )
    let toolEvent = publicEvent(
      id: "00000000-0000-0000-0000-000000000013",
      lineage: child,
      kind: .toolAuthorizationDenied
    )
    let childReceipt = try publicReceipt(
      lineage: child,
      events: [routeEvent, contextEvent, toolEvent]
    )
    let result = try AgentTaskResult(
      lineage: child,
      status: .denied,
      evidenceReferences: [
        .routingDecision(for: child.runID),
        .event(contextEvent),
        .event(toolEvent),
      ],
      receipt: AgentReceiptReference(
        runID: child.runID,
        rootHash: childReceipt.rootHash
      ),
      failureReason: AgentTaskSettlementReason(
        code: "policy_denied",
        message: "The requested tool was not authorized."
      ),
      timing: AgentTaskTiming(startedAt: publicEvidenceStart, endedAt: publicEvidenceStart)
    )
    let bundle = AgentReceiptBundle(
      receipts: [
        try publicReceipt(lineage: root),
        childReceipt,
      ],
      taskResults: [result]
    )

    try bundle.verify(maximumDepth: AgentRunDepth(1))
    #expect(child.runID.description == "00000000-0000-0000-0000-000000000002")
    #expect(result.evidenceReferences[0].kind == .routingDecision)
    #expect(result.evidenceReferences[1] == .event(contextEvent))
    #expect(result.evidenceReferences[2] == .event(toolEvent))
  }

  @Test("Every terminal settlement has one deterministic reason contract")
  func terminalSettlements() throws {
    let root = AgentRunLineage.root()
    let timing = try AgentTaskTiming(
      queuedAt: publicEvidenceStart,
      startedAt: publicEvidenceStart,
      endedAt: publicEvidenceStart
    )
    let failure = AgentTaskSettlementReason(code: "terminal", message: "Settled.")
    let cancellation = AgentTaskSettlementReason(code: "cancelled", message: "Cancelled.")

    let values = try [
      AgentTaskResult(lineage: root.descendant(), status: .succeeded, timing: timing),
      AgentTaskResult(
        lineage: root.descendant(),
        status: .denied,
        failureReason: failure,
        timing: timing
      ),
      AgentTaskResult(
        lineage: root.descendant(),
        status: .failed,
        failureReason: failure,
        timing: timing
      ),
      AgentTaskResult(
        lineage: root.descendant(),
        status: .cancelled,
        cancellationReason: cancellation,
        timing: timing
      ),
      AgentTaskResult(
        lineage: root.descendant(),
        status: .timedOut,
        failureReason: failure,
        timing: timing
      ),
      AgentTaskResult(
        lineage: root.descendant(),
        status: .ambiguousAfterCrash,
        failureReason: failure,
        timing: timing
      ),
    ]

    #expect(
      values.map(\.status) == [
        .succeeded, .denied, .failed, .cancelled, .timedOut, .ambiguousAfterCrash,
      ])
  }

  @Test("Receipt bundles round-trip through deterministic JSON and atomic files")
  func jsonAndFileRoundTrip() throws {
    let root = AgentRunLineage.root(
      runID: AgentRunID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
      )
    )
    let bundle = AgentReceiptBundle(receipts: [try publicReceipt(lineage: root)])
    let exporter = AgentReceiptBundleExporter()
    let compact = try exporter.data(for: bundle, prettyPrinted: false)
    let secondCompact = try exporter.data(for: bundle, prettyPrinted: false)
    #expect(compact == secondCompact)
    #expect(try exporter.decode(compact) == bundle)

    let directory = FileManager.default.temporaryDirectory.appending(
      path: "FoundationModelsAgent-public-evidence-\(root.runID)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "bundle.json", directoryHint: .notDirectory)
    try exporter.write(bundle, to: url)

    #expect(try exporter.decode(contentsOf: url) == bundle)
  }
}

private func publicEvent(
  id: String,
  lineage: AgentRunLineage,
  kind: FoundationModelsAgentEventKind
) -> FoundationModelsAgentEvent {
  FoundationModelsAgentEvent(
    id: UUID(uuidString: id)!,
    runID: lineage.runID.rawValue,
    timestamp: publicEvidenceStart,
    kind: kind,
    message: kind.rawValue,
    lineage: lineage
  )
}

private func publicReceipt(
  lineage: AgentRunLineage,
  events: [FoundationModelsAgentEvent]? = nil
) throws -> FoundationModelsAgentRunReceipt {
  let settled =
    events
    ?? [
      publicEvent(
        id: "00000000-0000-0000-0000-000000000010",
        lineage: lineage,
        kind: .runCompleted
      )
    ]
  let run = FoundationModelsAgentRun(
    id: lineage.runID.rawValue,
    startedAt: publicEvidenceStart,
    endedAt: publicEvidenceStart,
    usage: nil,
    events: settled,
    lineage: lineage
  )
  return try FoundationModelsAgentRunReceipt(run: run)
}

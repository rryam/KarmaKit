import Foundation
import FoundationModelsAgent
import FoundationModelsAgentTestSupport
import Testing

private actor LineageEventCapture {
  private(set) var events: [FoundationModelsAgentEvent] = []

  func append(_ event: FoundationModelsAgentEvent) {
    events.append(event)
  }
}

@Suite("Hierarchical execution evidence")
struct AgentExecutionEvidenceTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("AgentSession preserves nested lineage in runs, events, receipts, and exports")
  func nestedLineageRoundTrip() async throws {
    let rootResponse = try await AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "root")])
    ).respond(to: "Root")
    let rootLineage = try #require(rootResponse.run.lineage)
    let childLineage = try rootLineage.descendant()
    let observerCapture = LineageEventCapture()
    let childSession = try AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "child")]),
      observers: [
        ClosureFoundationModelsAgentObserver { await observerCapture.append($0) }
      ]
    )
    let childResponse = try await childSession.respond(to: "Child", lineage: childLineage)
    _ = await childSession.flushObservers()
    let observedChildEvents = await observerCapture.events
    let grandchildLineage = try childLineage.descendant(relationship: .background)
    let grandchildResponse = try await AgentSession(
      model: RecordedLanguageModel(steps: [.response(text: "grandchild")])
    ).respond(to: "Grandchild", lineage: grandchildLineage)

    #expect(rootLineage.relationship == .root)
    #expect(childResponse.run.lineage == childLineage)
    #expect(grandchildResponse.run.lineage == grandchildLineage)
    #expect(childResponse.run.events.allSatisfy { $0.lineage == childLineage })
    #expect(observedChildEvents.allSatisfy { $0.lineage == childLineage })

    let rootReceipt = try FoundationModelsAgentRunReceipt(run: rootResponse.run)
    let childReceipt = try FoundationModelsAgentRunReceipt(run: childResponse.run)
    let grandchildReceipt = try FoundationModelsAgentRunReceipt(run: grandchildResponse.run)
    let childResult = try AgentTaskResult(
      lineage: childLineage,
      status: .succeeded,
      outputReferences: [
        AgentEvidenceReference(id: "answer", kind: "generated-content")
      ],
      usage: childResponse.usage,
      receipt: AgentReceiptReference(
        runID: childLineage.runID,
        rootHash: childReceipt.rootHash
      ),
      timing: AgentTaskTiming(
        startedAt: childResponse.run.startedAt,
        endedAt: childResponse.run.endedAt
      )
    )
    let bundle = AgentReceiptBundle(
      receipts: [rootReceipt, childReceipt, grandchildReceipt],
      taskResults: [childResult]
    )

    try bundle.verify(maximumDepth: AgentRunDepth(2))

    let exporter = FoundationModelsAgentReceiptExporter()
    let decoded = try exporter.decode(exporter.data(for: grandchildResponse.run))
    #expect(decoded.lineage == grandchildLineage)
    #expect(decoded.verify())
  }

  @Test("Receipt bundles reject orphaned descendants")
  func orphanRejection() throws {
    let root = AgentRunLineage.root()
    let missingParent = AgentRunID()
    let child = try AgentRunLineage(
      runID: AgentRunID(),
      rootRunID: root.runID,
      parentRunID: missingParent,
      taskID: AgentTaskID(),
      depth: AgentRunDepth(1),
      relationship: .child
    )
    let bundle = AgentReceiptBundle(receipts: [
      try makeReceipt(lineage: root),
      try makeReceipt(lineage: child),
    ])

    expectEvidenceError(
      .orphanedRun(runID: child.runID, missingParentRunID: missingParent)
    ) {
      try bundle.verify()
    }
  }

  @Test("Receipt bundles reject cycles before accepting depth claims")
  func cycleRejection() throws {
    let root = AgentRunLineage.root()
    let firstID = AgentRunID()
    let secondID = AgentRunID()
    let first = try AgentRunLineage(
      runID: firstID,
      rootRunID: root.runID,
      parentRunID: secondID,
      taskID: AgentTaskID(),
      depth: AgentRunDepth(1),
      relationship: .child
    )
    let second = try AgentRunLineage(
      runID: secondID,
      rootRunID: root.runID,
      parentRunID: firstID,
      taskID: AgentTaskID(),
      depth: AgentRunDepth(2),
      relationship: .background
    )
    let bundle = AgentReceiptBundle(receipts: [
      try makeReceipt(lineage: root),
      try makeReceipt(lineage: first),
      try makeReceipt(lineage: second),
    ])

    do {
      try bundle.verify()
      Issue.record("Expected a lineage cycle to be rejected.")
    } catch let error as AgentExecutionEvidenceError {
      guard case .cycleDetected = error else {
        Issue.record("Expected cycleDetected, received \(error).")
        return
      }
    }
  }

  @Test("Receipt bundles validate parent depth and caller depth limits")
  func depthValidation() throws {
    let root = AgentRunLineage.root()
    let inconsistent = try AgentRunLineage(
      runID: AgentRunID(),
      rootRunID: root.runID,
      parentRunID: root.runID,
      taskID: AgentTaskID(),
      depth: AgentRunDepth(2),
      relationship: .child
    )
    let inconsistentBundle = AgentReceiptBundle(receipts: [
      try makeReceipt(lineage: root),
      try makeReceipt(lineage: inconsistent),
    ])
    expectEvidenceError(.inconsistentDepth(runID: inconsistent.runID)) {
      try inconsistentBundle.verify()
    }

    let child = try root.descendant()
    let boundedBundle = AgentReceiptBundle(receipts: [
      try makeReceipt(lineage: root),
      try makeReceipt(lineage: child),
    ])
    expectEvidenceError(
      .maximumDepthExceeded(runID: child.runID, maximum: .root)
    ) {
      try boundedBundle.verify(maximumDepth: .root)
    }
  }

  @Test("Lineage changes invalidate the receipt hash chain")
  func lineageTamperDetection() throws {
    let root = AgentRunLineage.root()
    let child = try root.descendant()
    let valid = try makeReceipt(lineage: child)
    let rewritten = try AgentRunLineage(
      runID: child.runID,
      rootRunID: child.rootRunID,
      parentRunID: child.parentRunID,
      taskID: AgentTaskID(),
      depth: child.depth,
      relationship: child.relationship
    )
    let tampered = FoundationModelsAgentRunReceipt(
      runID: valid.runID,
      receipts: valid.receipts,
      rootHash: valid.rootHash,
      lineage: rewritten
    )

    #expect(valid.verify())
    #expect(!tampered.verify())
  }

  @Test("Task results round-trip every settlement and evidence field")
  func taskResultRoundTrip() throws {
    let lineage = try AgentRunLineage.root().descendant(relationship: .background)
    let timing = try AgentTaskTiming(
      queuedAt: start,
      startedAt: start.addingTimeInterval(1),
      endedAt: start.addingTimeInterval(3)
    )
    let result = try AgentTaskResult(
      lineage: lineage,
      status: .ambiguousAfterCrash,
      outputReferences: [
        AgentEvidenceReference(
          id: "partial-output",
          kind: "file",
          location: "artifact://partial"
        )
      ],
      evidenceReferences: [
        AgentEvidenceReference(id: "log", kind: "trace", location: "artifact://trace")
      ],
      usage: FoundationModelsAgentUsage(
        inputTokens: 12,
        cachedInputTokens: 2,
        outputTokens: 4,
        reasoningTokens: 1
      ),
      receipt: AgentReceiptReference(runID: lineage.runID, rootHash: "partial-root"),
      failureReason: AgentTaskSettlementReason(
        code: "process_crash",
        message: "The external write may have completed."
      ),
      timing: timing
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970

    let decoded = try decoder.decode(AgentTaskResult.self, from: encoder.encode(result))

    #expect(decoded == result)
    #expect(decoded.status == .ambiguousAfterCrash)
    #expect(decoded.timing.duration == 2)
  }

  @Test("Cancellation is terminal and requires a cancellation reason")
  func cancellationSettlement() throws {
    let lineage = try AgentRunLineage.root().descendant()
    let timing = try AgentTaskTiming(startedAt: start, endedAt: start)
    let cancelled = try AgentTaskResult(
      lineage: lineage,
      status: .cancelled,
      cancellationReason: AgentTaskSettlementReason(
        code: "parent_cancelled",
        message: "The parent no longer needs this task."
      ),
      timing: timing
    )

    #expect(cancelled.status == .cancelled)
    #expect(cancelled.cancellationReason?.code == "parent_cancelled")
    expectEvidenceError(.invalidTaskSettlement(.cancelled)) {
      _ = try AgentTaskResult(
        lineage: lineage,
        status: .cancelled,
        timing: timing
      )
    }
  }

  @Test("Task-result redaction covers outputs, evidence, and reasons")
  func taskResultRedaction() throws {
    let lineage = try AgentRunLineage.root().descendant()
    let result = try AgentTaskResult(
      lineage: lineage,
      status: .failed,
      outputReferences: [
        AgentEvidenceReference(
          id: "Bearer output-secret",
          kind: "output",
          location: "token=private-output"
        )
      ],
      evidenceReferences: [
        AgentEvidenceReference(
          id: "trace",
          kind: "log",
          attributes: ["credential": "sk-1234567890"]
        )
      ],
      failureReason: AgentTaskSettlementReason(
        code: "api_key=private-code",
        message: "Bearer private-message"
      ),
      timing: AgentTaskTiming(startedAt: start, endedAt: start)
    )

    let redacted = result.redacted(using: .standard)
    let data = try JSONEncoder().encode(redacted)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(!json.contains("private"))
    #expect(!json.contains("1234567890"))
    #expect(json.contains("REDACTED"))
  }

  @Test("Receipt bundles reject duplicate task settlements")
  func duplicateTaskSettlement() throws {
    let root = AgentRunLineage.root()
    let child = try root.descendant()
    let taskID = try #require(child.taskID)
    let result = try AgentTaskResult(
      lineage: child,
      status: .succeeded,
      timing: AgentTaskTiming(startedAt: start, endedAt: start)
    )
    let bundle = AgentReceiptBundle(
      receipts: [
        try makeReceipt(lineage: root),
        try makeReceipt(lineage: child),
      ],
      taskResults: [result, result]
    )

    expectEvidenceError(.duplicateTaskID(taskID)) {
      try bundle.verify()
    }
  }

  @Test("Legacy receipt fixtures without lineage still decode and verify")
  func legacyReceiptFixture() throws {
    let fixture = Data(
      """
      {
        "receipts": [
          {
            "event": {
              "attributes": {},
              "id": "00000000-0000-0000-0000-000000000010",
              "kind": "runCompleted",
              "message": "settled",
              "runID": "00000000-0000-0000-0000-000000000001",
              "timestamp": 1800000000000
            },
            "hash": "f7aae76f07079a8b8b93aed1bb89cb7d05d9b0dbc973aae1018c367e18f7de37",
            "index": 0,
            "previousHash": "89a232afe960f463f488946d5d5c5db2030c4e133a81c49c4e78f4d3c62aaaac"
          }
        ],
        "rootHash": "f7aae76f07079a8b8b93aed1bb89cb7d05d9b0dbc973aae1018c367e18f7de37",
        "runID": "00000000-0000-0000-0000-000000000001"
      }
      """.utf8
    )

    let decoded = try FoundationModelsAgentReceiptExporter().decode(fixture)

    #expect(decoded.lineage == nil)
    #expect(decoded.verify())
    try AgentReceiptBundle(receipts: [decoded]).verify()

    let runFixture = Data(
      """
      {
        "endedAt": 1800000000000,
        "events": [
          {
            "attributes": {},
            "id": "00000000-0000-0000-0000-000000000010",
            "kind": "runCompleted",
            "message": "settled",
            "runID": "00000000-0000-0000-0000-000000000001",
            "timestamp": 1800000000000
          }
        ],
        "id": "00000000-0000-0000-0000-000000000001",
        "startedAt": 1800000000000
      }
      """.utf8
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let legacyRun = try decoder.decode(FoundationModelsAgentRun.self, from: runFixture)

    #expect(legacyRun.lineage == nil)
    #expect(legacyRun.events[0].lineage == nil)
    #expect(FoundationModelsAgentCheckpoint.currentFormatVersion == 1)
  }

  private func makeReceipt(lineage: AgentRunLineage) throws
    -> FoundationModelsAgentRunReceipt
  {
    let event = FoundationModelsAgentEvent(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
      runID: lineage.runID.rawValue,
      timestamp: start,
      kind: .runCompleted,
      message: "settled",
      lineage: lineage
    )
    let run = FoundationModelsAgentRun(
      id: lineage.runID.rawValue,
      startedAt: start,
      endedAt: start,
      usage: nil,
      events: [event],
      lineage: lineage
    )
    return try FoundationModelsAgentRunReceipt(run: run)
  }

  private func expectEvidenceError(
    _ expected: AgentExecutionEvidenceError,
    performing operation: () throws -> Void
  ) {
    do {
      try operation()
      Issue.record("Expected \(expected), but the operation succeeded.")
    } catch let error as AgentExecutionEvidenceError {
      #expect(error == expected)
    } catch {
      Issue.record("Expected \(expected), received \(error).")
    }
  }
}

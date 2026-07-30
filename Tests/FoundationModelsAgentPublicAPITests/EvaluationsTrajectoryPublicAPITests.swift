import Foundation
import FoundationModels
import FoundationModelsAgent
import Testing

private let trajectoryDate = Date(timeIntervalSince1970: 1_800_100_000)

private struct PublicOpaqueSegment: Transcript.CustomSegment {
  struct Content: Codable, Equatable, Sendable {
    let value: String
  }

  let id: String
  let content: Content
}

@Suite("Evaluation trajectory public API consumer")
struct EvaluationsTrajectoryPublicAPITests {
  @Test("Verified evidence graph preserves child, task, routing, and context relationships")
  func canonicalEvidenceGraph() throws {
    let fixture = try EvidenceFixture()
    let trajectory = try FoundationModelsAgentTrajectory(
      transcripts: [
        fixture.root.runID: successfulTranscript(callID: "root-call"),
        fixture.children[0].runID: successfulTranscript(callID: "child-call"),
      ],
      evidenceBundle: fixture.bundle
    )
    let graph = try #require(trajectory.evidenceGraph)

    #expect(graph.runs.count == 7)
    #expect(graph.runs.map(\.lineage?.relationship).first == .root)
    #expect(
      graph.runs.dropFirst().allSatisfy {
        $0.lineage?.parentRunID == fixture.root.runID.description
      })
    #expect(
      graph.tasks.map(\.status) == [
        .succeeded, .denied, .failed, .cancelled, .timedOut, .ambiguousAfterCrash,
      ])
    #expect(graph.runs[1].steps.filter { $0.kind == .toolCall }.count == 1)
    #expect(
      graph.tasks[0].evidenceReferences.map(\.kind)
        == [
          AgentEvidenceReferenceKind.routingDecision.rawValue,
          AgentEvidenceReferenceKind.event.rawValue,
        ])
    let childEventKinds = graph.runs[1].events.map(\.kind)
    #expect(childEventKinds.contains(.routeSelected))
    #expect(childEventKinds.contains(.contextBudgetEvaluated))
    #expect(
      trajectory.issues.filter { $0.kind == .missingNativeTranscript }.count == 5
    )
  }

  @Test("Malformed native turns stay authoritative over conflicting canonical outcomes")
  func malformedNativeTranscriptPrecedence() throws {
    let fixture = try EvidenceFixture(
      firstChildEvents: [
        (.toolExecutionFailed, ["tool": "lookup", "native_call_id": "completed-call"]),
        (.toolExecutionCompleted, ["tool": "lookup", "native_call_id": "missing-output"]),
      ]
    )
    let malformed = Transcript(entries: [
      .toolCalls(
        Transcript.ToolCalls(
          id: "duplicate-group",
          [
            toolCall(id: "duplicate", query: "first"),
            toolCall(id: "duplicate", query: "second"),
            toolCall(id: "completed-call", query: "completed"),
            toolCall(id: "missing-output", query: "missing"),
          ]
        )
      ),
      .toolOutput(
        Transcript.ToolOutput(
          id: "duplicate",
          toolName: "lookup",
          segments: [.text(.init(id: "duplicate-output", content: "ambiguous"))]
        )
      ),
      .toolOutput(
        Transcript.ToolOutput(
          id: "completed-call",
          toolName: "lookup",
          segments: [.text(.init(id: "completed-output", content: "native success"))]
        )
      ),
      .toolOutput(
        Transcript.ToolOutput(
          id: "orphan",
          toolName: "lookup",
          segments: [
            .text(.init(id: "orphan-output", content: "orphan")),
            .custom(
              PublicOpaqueSegment(
                id: "opaque-output",
                content: .init(value: "provider-owned")
              )
            ),
          ]
        )
      ),
    ])
    let trajectory = try FoundationModelsAgentTrajectory(
      transcripts: [fixture.children[0].runID: malformed],
      evidenceBundle: fixture.bundle
    )
    let child = try #require(
      trajectory.evidenceGraph?.runs.first {
        $0.lineage?.runID == fixture.children[0].runID.description
      })
    let calls = child.steps.filter { $0.kind == .toolCall }

    #expect(calls.map(\.id) == ["duplicate", "duplicate", "completed-call", "missing-output"])
    #expect(calls[0].toolOutcome == .incomplete)
    #expect(calls[1].toolOutcome == .incomplete)
    #expect(calls[2].toolOutcome == .succeeded)
    #expect(calls[3].toolOutcome == .succeeded)
    #expect(child.issues.map(\.kind).contains(.duplicateToolCallID))
    #expect(child.issues.map(\.kind).contains(.ambiguousToolOutputLinkage))
    #expect(child.issues.map(\.kind).contains(.orphanedToolOutput))
    #expect(child.issues.map(\.kind).contains(.unsupportedCustomSegment))
    #expect(
      child.issues.contains {
        $0.kind == .ambiguousToolOutcome && $0.entryID == "completed-call"
      })
    #expect(
      child.issues.contains {
        $0.kind == .orphanedToolCall && $0.entryID == "missing-output"
      })
  }

  @Test("Sanitized fixture JSON and atomic files round-trip deterministically")
  func deterministicSanitizedRoundTrips() throws {
    let fixture = try EvidenceFixture()
    let trajectory = try FoundationModelsAgentTrajectory(
      transcripts: [
        fixture.root.runID: successfulTranscript(callID: "native-root-call"),
        fixture.children[0].runID: successfulTranscript(callID: "native-child-call"),
      ],
      evidenceBundle: fixture.bundle
    )
    let exporter = FoundationModelsAgentTrajectoryFixtureExporter()
    let first = try exporter.data(
      for: trajectory,
      named: "public graph fixture",
      expectedDestination: "done"
    )
    let second = try exporter.data(
      for: trajectory,
      named: "public graph fixture",
      expectedDestination: "done"
    )
    let json = String(decoding: first, as: UTF8.self)
    let decoded = try exporter.decode(first)

    #expect(first == second)
    #expect(!json.contains("00000000-0000-0000-0000"))
    #expect(!json.contains("native-root-call"))
    #expect(!json.contains("fixture-value"))
    #expect(decoded.trajectory.evidenceGraph?.runs.first?.runID == "run-0000")
    #expect(decoded.trajectory.evidenceGraph?.tasks.first?.lineage.taskID == "task-0000")

    let url = FileManager.default.temporaryDirectory.appending(
      path: "foundation-models-agent-public-trajectory.json",
      directoryHint: .notDirectory
    )
    defer { try? FileManager.default.removeItem(at: url) }
    try exporter.write(
      trajectory,
      named: "public graph fixture",
      expectedDestination: "done",
      to: url
    )
    #expect(try exporter.decode(contentsOf: url) == decoded)
  }

  @Test("Version 1 trajectory fixtures remain decodable without invented evidence")
  func legacyFixtureDecode() throws {
    let legacy = Data(
      """
      {
        "formatVersion": 1,
        "name": "legacy",
        "trajectory": {
          "formatVersion": 1,
          "finalStatus": "completed",
          "issues": [],
          "steps": []
        }
      }
      """.utf8
    )

    let fixture = try FoundationModelsAgentTrajectoryFixtureExporter().decode(legacy)

    #expect(fixture.formatVersion == 1)
    #expect(fixture.trajectory.formatVersion == 1)
    #expect(fixture.trajectory.evidenceGraph == nil)
  }

  @Test("Multiple canonical roots remain explicit instead of selecting one")
  func multipleRootsRemainExplicit() throws {
    let first = AgentRunLineage.root(runID: AgentRunID(rawValue: fixtureUUID(401)))
    let second = AgentRunLineage.root(runID: AgentRunID(rawValue: fixtureUUID(402)))
    let bundle = AgentReceiptBundle(receipts: [
      try makeReceipt(
        lineage: first,
        events: [makeEvent(id: 411, lineage: first, kind: .runCompleted)]
      ),
      try makeReceipt(
        lineage: second,
        events: [makeEvent(id: 412, lineage: second, kind: .runCompleted)]
      ),
    ])

    let trajectory = try FoundationModelsAgentTrajectory(
      transcripts: [
        first.runID: successfulTranscript(callID: "first-root"),
        second.runID: successfulTranscript(callID: "second-root"),
      ],
      evidenceBundle: bundle
    )

    #expect(trajectory.runID == nil)
    #expect(trajectory.steps.isEmpty)
    #expect(trajectory.finalStatus == .incomplete)
    #expect(trajectory.issues.map(\.kind).contains(.ambiguousRootRun))
    #expect(trajectory.evidenceGraph?.runs.count == 2)
  }
}

private struct EvidenceFixture {
  let root: AgentRunLineage
  let children: [AgentRunLineage]
  let bundle: AgentReceiptBundle

  init(
    firstChildEvents: [(FoundationModelsAgentEventKind, [String: String])] = []
  ) throws {
    let rootLineage = AgentRunLineage.root(
      runID: AgentRunID(rawValue: fixtureUUID(1))
    )
    let childLineages = try (0..<6).map { index in
      try rootLineage.descendant(
        runID: AgentRunID(rawValue: fixtureUUID(index + 2)),
        taskID: AgentTaskID(rawValue: fixtureUUID(index + 20))
      )
    }
    var receipts = [
      try makeReceipt(
        lineage: rootLineage,
        events: [makeEvent(id: 100, lineage: rootLineage, kind: .runCompleted)]
      )
    ]
    var results: [AgentTaskResult] = []
    let statuses: [AgentTaskSettlementStatus] = [
      .succeeded, .denied, .failed, .cancelled, .timedOut, .ambiguousAfterCrash,
    ]
    for (index, child) in childLineages.enumerated() {
      var events = [
        makeEvent(
          id: 110 + index * 10,
          lineage: child,
          kind: .routeSelected,
          attributes: ["route_id": "route-\(index)"]
        ),
        makeEvent(
          id: 111 + index * 10,
          lineage: child,
          kind: .contextBudgetEvaluated,
          attributes: ["before_total_input_tokens": "12"]
        ),
      ]
      if index == 0 {
        events.append(
          contentsOf: firstChildEvents.enumerated().map { offset, value in
            makeEvent(
              id: 112 + offset,
              lineage: child,
              kind: value.0,
              attributes: value.1
            )
          })
      }
      events.append(
        makeEvent(
          id: 119 + index * 10,
          lineage: child,
          kind: statuses[index] == .cancelled ? .runCancelled : .runCompleted
        )
      )
      let receipt = try makeReceipt(lineage: child, events: events)
      receipts.append(receipt)
      let reason = AgentTaskSettlementReason(
        code: "terminal-\(index)",
        message: "terminal status \(index)"
      )
      results.append(
        try AgentTaskResult(
          lineage: child,
          status: statuses[index],
          evidenceReferences: [
            .routingDecision(for: child.runID),
            .event(events[1]),
          ],
          receipt: AgentReceiptReference(runID: child.runID, rootHash: receipt.rootHash),
          failureReason: [.denied, .failed, .timedOut, .ambiguousAfterCrash].contains(
            statuses[index]
          )
            ? reason : nil,
          cancellationReason: statuses[index] == .cancelled ? reason : nil,
          timing: AgentTaskTiming(startedAt: trajectoryDate, endedAt: trajectoryDate)
        )
      )
    }
    root = rootLineage
    children = childLineages
    bundle = AgentReceiptBundle(receipts: receipts, taskResults: results)
  }
}

private func successfulTranscript(callID: String) -> Transcript {
  let credentialName = ["api", "key"].joined(separator: "_")
  return Transcript(entries: [
    .toolCalls(
      Transcript.ToolCalls(
        id: "\(callID)-group",
        [toolCall(id: callID, query: "\(credentialName)=fixture-value")]
      )
    ),
    .toolOutput(
      Transcript.ToolOutput(
        id: callID,
        toolName: "lookup",
        segments: [.text(.init(id: "\(callID)-output", content: "done"))]
      )
    ),
    .response(
      Transcript.Response(
        id: "\(callID)-response",
        metadata: [:],
        segments: [.text(.init(id: "\(callID)-text", content: "done"))]
      )
    ),
  ])
}

private func toolCall(id: String, query: String) -> Transcript.ToolCall {
  Transcript.ToolCall(
    id: id,
    toolName: "lookup",
    arguments: GeneratedContent(properties: ["query": query])
  )
}

private func makeEvent(
  id: Int,
  lineage: AgentRunLineage,
  kind: FoundationModelsAgentEventKind,
  attributes: [String: String] = [:]
) -> FoundationModelsAgentEvent {
  FoundationModelsAgentEvent(
    id: fixtureUUID(id),
    runID: lineage.runID.rawValue,
    timestamp: trajectoryDate,
    kind: kind,
    message: kind.rawValue,
    attributes: attributes,
    lineage: lineage
  )
}

private func makeReceipt(
  lineage: AgentRunLineage,
  events: [FoundationModelsAgentEvent]
) throws -> FoundationModelsAgentRunReceipt {
  try FoundationModelsAgentRunReceipt(
    run: FoundationModelsAgentRun(
      id: lineage.runID.rawValue,
      startedAt: trajectoryDate,
      endedAt: trajectoryDate,
      usage: nil,
      events: events,
      lineage: lineage
    )
  )
}

private func fixtureUUID(_ value: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

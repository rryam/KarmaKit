import Foundation
import FoundationModels
import FoundationModelsAgent
import Testing

private struct TrajectoryCustomSegment: Transcript.CustomSegment {
  struct Content: Codable, Equatable, Sendable {
    let value: String
  }

  let id: String
  let content: Content
}

@Suite("FoundationModelsAgent evaluation trajectories")
struct FoundationModelsAgentTrajectoryTests {
  @Test("Preserves tool ordering, canonical arguments, linkage, and denied outcomes")
  func orderedToolEvidence() throws {
    let lookup = Transcript.ToolCall(
      id: "call-lookup",
      toolName: "lookup",
      arguments: GeneratedContent(properties: [
        "z": 2,
        "query": "Bearer private-token",
        "a": true,
      ])
    )
    let denied = Transcript.ToolCall(
      id: "call-delete",
      toolName: "delete",
      arguments: GeneratedContent(properties: ["record_id": "123"])
    )
    let transcript = Transcript(entries: [
      .prompt(
        Transcript.Prompt(
          id: "prompt-native",
          segments: [.text(.init(id: "prompt-text", content: "Find then delete"))]
        )
      ),
      .toolCalls(
        Transcript.ToolCalls(id: "call-group-native", [lookup, denied])
      ),
      .toolOutput(
        Transcript.ToolOutput(
          id: "call-lookup",
          toolName: "lookup",
          segments: [.text(.init(id: "output-text", content: "found"))]
        )
      ),
      .response(
        Transcript.Response(
          id: "response-native",
          metadata: [:],
          segments: [.text(.init(id: "response-text", content: "Finished"))]
        )
      ),
    ])
    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let run = FoundationModelsAgentRun(
      id: runID,
      startedAt: Date(timeIntervalSince1970: 0),
      endedAt: Date(timeIntervalSince1970: 1),
      usage: nil,
      events: [
        FoundationModelsAgentEvent(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
          runID: runID,
          timestamp: Date(timeIntervalSince1970: 0),
          kind: .toolAuthorizationDenied,
          message: "Denied",
          attributes: ["tool": "delete"]
        ),
        FoundationModelsAgentEvent(
          id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
          runID: runID,
          timestamp: Date(timeIntervalSince1970: 1),
          kind: .runFailed,
          message: "Failed"
        ),
      ]
    )

    let trajectory = FoundationModelsAgentTrajectory(transcript: transcript, run: run)

    #expect(trajectory.finalStatus == .failed)
    #expect(trajectory.toolCalls.map(\.toolName) == ["lookup", "delete"])
    #expect(
      trajectory.toolCalls[0].canonicalArgumentsJSON
        == #"{"a":true,"query":"Bearer [REDACTED]","z":2}"#
    )
    #expect(trajectory.toolCalls[0].parentID == "call-group-native")
    #expect(trajectory.toolCalls[0].toolOutcome == .succeeded)
    #expect(trajectory.toolCalls[1].toolOutcome == .denied)
    #expect(
      !trajectory.issues.contains {
        $0.kind == .orphanedToolCall && $0.entryID == "call-delete"
      }
    )
    let output = try #require(trajectory.steps.first { $0.kind == .toolOutput })
    #expect(output.parentID == "call-lookup")
    #expect(trajectory.destinationText == "Finished")
  }

  @Test("Surfaces malformed arguments, orphaned turns, and custom segments")
  func malformedAndUnsupportedEvidence() {
    let transcript = Transcript(entries: [
      .toolCalls(
        Transcript.ToolCalls(
          id: "empty-group",
          [
            Transcript.ToolCall(
              id: "malformed-call",
              toolName: "bad",
              arguments: GeneratedContent("scalar")
            )
          ]
        )
      ),
      .toolOutput(
        Transcript.ToolOutput(
          id: "orphan-output",
          toolName: "unknown",
          segments: [
            .custom(
              TrajectoryCustomSegment(
                id: "provider-segment",
                content: .init(value: "opaque")
              )
            )
          ]
        )
      ),
    ])

    let trajectoryWithoutRun = FoundationModelsAgentTrajectory(transcript: transcript)
    let kinds = Set(trajectoryWithoutRun.issues.map(\.kind))

    #expect(kinds.contains(.malformedToolArguments))
    #expect(kinds.contains(.unresolvedToolCall))
    #expect(!kinds.contains(.orphanedToolCall))
    #expect(kinds.contains(.orphanedToolOutput))
    #expect(kinds.contains(.unsupportedCustomSegment))
    #expect(
      trajectoryWithoutRun.steps
        .flatMap(\.segments)
        .contains {
          $0.kind == .unsupportedCustom
            && $0.unsupportedType?.contains("TrajectoryCustomSegment") == true
        }
    )

    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let trajectoryWithCompletedRun = FoundationModelsAgentTrajectory(
      transcript: transcript,
      run: FoundationModelsAgentRun(
        id: runID,
        startedAt: Date(timeIntervalSince1970: 0),
        endedAt: Date(timeIntervalSince1970: 1),
        usage: nil,
        events: [
          FoundationModelsAgentEvent(
            runID: runID,
            timestamp: Date(timeIntervalSince1970: 1),
            kind: .runCompleted,
            message: "Completed"
          )
        ]
      )
    )
    #expect(trajectoryWithCompletedRun.issues.map(\.kind).contains(.orphanedToolCall))
  }

  @Test("Keeps duplicate native call IDs and their output linkage ambiguous")
  func duplicateToolCallIDs() {
    let transcript = Transcript(entries: [
      .toolCalls(
        Transcript.ToolCalls(
          id: "duplicate-group",
          [
            Transcript.ToolCall(
              id: "duplicate-call",
              toolName: "first",
              arguments: GeneratedContent(properties: ["value": 1])
            ),
            Transcript.ToolCall(
              id: "duplicate-call",
              toolName: "second",
              arguments: GeneratedContent(properties: ["value": 2])
            ),
          ]
        )
      ),
      .toolOutput(
        Transcript.ToolOutput(
          id: "duplicate-call",
          toolName: "second",
          segments: [.text(.init(id: "duplicate-output", content: "done"))]
        )
      ),
    ])

    let trajectory = FoundationModelsAgentTrajectory(transcript: transcript)
    let output = trajectory.steps.first { $0.kind == .toolOutput }

    #expect(trajectory.toolCalls.map(\.toolOutcome) == [.incomplete, .incomplete])
    #expect(output?.parentID == nil)
    #expect(trajectory.issues.map(\.kind).contains(.duplicateToolCallID))
    #expect(trajectory.issues.map(\.kind).contains(.ambiguousToolOutputLinkage))
    #expect(
      trajectory.issues.filter { $0.kind == .unresolvedToolCall }.count == 2
    )
  }

  @Test("Keeps a missing transcript output explicit after audited success")
  func auditedSuccessWithoutTranscriptOutput() {
    let transcript = Transcript(entries: [
      .toolCalls(
        Transcript.ToolCalls(
          id: "lookup-group",
          [
            Transcript.ToolCall(
              id: "lookup-call",
              toolName: "lookup",
              arguments: GeneratedContent(properties: ["query": "swift"])
            )
          ]
        )
      )
    ])
    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
    let run = FoundationModelsAgentRun(
      id: runID,
      startedAt: Date(timeIntervalSince1970: 0),
      endedAt: Date(timeIntervalSince1970: 1),
      usage: nil,
      events: [
        FoundationModelsAgentEvent(
          runID: runID,
          kind: .toolExecutionCompleted,
          message: "Completed",
          attributes: ["tool": "lookup"]
        ),
        FoundationModelsAgentEvent(
          runID: runID,
          kind: .runCompleted,
          message: "Completed"
        ),
      ]
    )

    let trajectory = FoundationModelsAgentTrajectory(transcript: transcript, run: run)

    #expect(trajectory.toolCalls.first?.toolOutcome == .succeeded)
    #expect(
      trajectory.issues.contains {
        $0.kind == .orphanedToolCall && $0.entryID == "lookup-call"
      }
    )
  }

  @Test("Correlates repeated tool outcomes without overwriting native output evidence")
  func repeatedToolOutcomeEvidence() {
    let firstCall = Transcript.ToolCall(
      id: "first-lookup",
      toolName: "lookup",
      arguments: GeneratedContent(properties: ["query": "first"])
    )
    let secondCall = Transcript.ToolCall(
      id: "second-lookup",
      toolName: "lookup",
      arguments: GeneratedContent(properties: ["query": "second"])
    )
    let transcript = Transcript(entries: [
      .toolCalls(Transcript.ToolCalls(id: "lookup-group", [firstCall, secondCall])),
      .toolOutput(
        Transcript.ToolOutput(
          id: "first-lookup",
          toolName: "lookup",
          segments: [.text(.init(id: "first-output", content: "found"))]
        )
      ),
    ])
    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    let run = FoundationModelsAgentRun(
      id: runID,
      startedAt: Date(timeIntervalSince1970: 0),
      endedAt: Date(timeIntervalSince1970: 1),
      usage: nil,
      events: [
        FoundationModelsAgentEvent(
          runID: runID,
          timestamp: Date(timeIntervalSince1970: 0),
          kind: .toolExecutionCompleted,
          message: "Completed",
          attributes: ["tool": "lookup"]
        ),
        FoundationModelsAgentEvent(
          runID: runID,
          timestamp: Date(timeIntervalSince1970: 1),
          kind: .toolAuthorizationDenied,
          message: "Denied",
          attributes: ["tool": "lookup"]
        ),
      ]
    )

    let trajectory = FoundationModelsAgentTrajectory(transcript: transcript, run: run)

    #expect(trajectory.toolCalls.map(\.toolOutcome) == [.succeeded, .denied])
    #expect(!trajectory.issues.map(\.kind).contains(.ambiguousToolOutcome))
    #expect(!trajectory.issues.map(\.kind).contains(.orphanedToolCall))
  }

  @Test("Surfaces ambiguous outcomes for indistinguishable repeated calls")
  func ambiguousRepeatedToolOutcomeEvidence() {
    let transcript = Transcript(entries: [
      .toolCalls(
        Transcript.ToolCalls(
          id: "lookup-group",
          [
            Transcript.ToolCall(
              id: "first-lookup",
              toolName: "lookup",
              arguments: GeneratedContent(properties: ["query": "first"])
            ),
            Transcript.ToolCall(
              id: "second-lookup",
              toolName: "lookup",
              arguments: GeneratedContent(properties: ["query": "second"])
            ),
          ]
        )
      )
    ])
    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
    let run = FoundationModelsAgentRun(
      id: runID,
      startedAt: Date(timeIntervalSince1970: 0),
      endedAt: Date(timeIntervalSince1970: 1),
      usage: nil,
      events: [
        FoundationModelsAgentEvent(
          runID: runID,
          kind: .toolAuthorizationDenied,
          message: "Denied",
          attributes: ["tool": "lookup"]
        ),
        FoundationModelsAgentEvent(
          runID: runID,
          kind: .toolExecutionFailed,
          message: "Failed",
          attributes: ["tool": "lookup"]
        ),
      ]
    )

    let trajectory = FoundationModelsAgentTrajectory(transcript: transcript, run: run)

    #expect(trajectory.toolCalls.map(\.toolOutcome) == [.incomplete, .incomplete])
    #expect(
      trajectory.issues.filter { $0.kind == .ambiguousToolOutcome }.map(\.entryID)
        == ["first-lookup", "second-lookup"]
    )
    #expect(
      trajectory.issues.filter { $0.kind == .unresolvedToolCall }.map(\.entryID)
        == ["first-lookup", "second-lookup"]
    )
  }

  @Test("Redacts sensitive argument keys recursively")
  func recursiveArgumentRedaction() throws {
    let passwordKey = ["pass", "word"].joined()
    let call = Transcript.ToolCall(
      id: "secret-call",
      toolName: "login",
      arguments: GeneratedContent(properties: [
        "account": "example-account",
        "access_token": "opaque-access-value",
        "nested": GeneratedContent(properties: [
          passwordKey: "redaction-sentinel",
          "visible": "ok",
        ]),
      ])
    )
    let trajectory = FoundationModelsAgentTrajectory(
      transcript: Transcript(entries: [
        .toolCalls(Transcript.ToolCalls(id: "secret-group", [call]))
      ])
    )
    let arguments = try #require(trajectory.toolCalls.first?.canonicalArgumentsJSON)

    #expect(arguments.contains("\"\(passwordKey)\":\"[REDACTED]\""))
    #expect(arguments.contains(#""access_token":"[REDACTED]""#))
    #expect(arguments.contains(#""visible":"ok""#))
    #expect(!arguments.contains("redaction-sentinel"))
    #expect(!arguments.contains("opaque-access-value"))
  }

  @Test("Fixture export is deterministic and remaps native identifiers")
  func deterministicFixtureExport() throws {
    let call = Transcript.ToolCall(
      id: "random-native-call",
      toolName: "lookup",
      arguments: GeneratedContent(properties: ["query": "weather"])
    )
    let trajectory = FoundationModelsAgentTrajectory(
      transcript: Transcript(entries: [
        .toolCalls(Transcript.ToolCalls(id: "random-native-group", [call])),
        .toolOutput(
          Transcript.ToolOutput(
            id: "random-native-call",
            toolName: "lookup",
            segments: [.text(.init(id: "random-native-segment", content: "sunny"))]
          )
        ),
      ])
    )
    let exporter = FoundationModelsAgentTrajectoryFixtureExporter()

    let first = try exporter.data(
      for: trajectory,
      named: "weather lookup",
      expectedDestination: "sunny"
    )
    let second = try exporter.data(
      for: trajectory,
      named: "weather lookup",
      expectedDestination: "sunny"
    )
    let encoded = String(decoding: first, as: UTF8.self)
    let fixture = try exporter.decode(first)

    #expect(first == second)
    #expect(!encoded.contains("random-native"))
    #expect(fixture.trajectory.runID == nil)
    let fixtureCall = try #require(fixture.trajectory.toolCalls.first)
    let fixtureOutput = try #require(
      fixture.trajectory.steps.first { $0.kind == .toolOutput }
    )
    #expect(fixtureCall.parentID == "step-0000")
    #expect(fixtureOutput.id != fixtureCall.id)
    #expect(fixtureOutput.parentID == fixtureCall.id)
    #expect(Set(fixture.trajectory.steps.map(\.id)).count == fixture.trajectory.steps.count)
  }
}

import Evaluations
import FoundationModels
import FoundationModelsAgent
import FoundationModelsAgentEvaluations
import Testing

@Suite("FoundationModelsAgent Xcode 27 Evaluations bridge")
struct FoundationModelsAgentEvaluationsTests {
  @Test("Builds exact ordered and disallowed trajectory expectations")
  func trajectoryExpectation() throws {
    let trajectory = FoundationModelsAgentTrajectory(
      finalStatus: .completed,
      steps: [
        .init(
          sequence: 0,
          id: "search-call",
          parentID: "search-group",
          kind: .toolCall,
          toolName: "search",
          canonicalArgumentsJSON: #"{"count":2,"fresh":true,"query":"swift"}"#,
          toolOutcome: .succeeded
        )
      ]
    )

    let expectation = try TrajectoryExpectation(
      foundationModelsAgentTrajectory: trajectory,
      disallowedToolNames: ["delete", "delete", "purchase"],
      allowsAdditionalToolCalls: false
    )

    #expect(expectation.ordered.map(\.name) == ["search"])
    #expect(expectation.ordered.first?.arguments.count == 3)
    #expect(expectation.disallowed.map(\.name) == ["delete", "purchase"])
    #expect(!expectation.allowsAdditionalCalls)
  }

  @Test("Rejects nested exact arguments instead of weakening them")
  func nestedArgumentsRemainExplicit() {
    let step = FoundationModelsAgentTrajectory.Step(
      sequence: 0,
      id: "nested-call",
      kind: .toolCall,
      toolName: "search",
      canonicalArgumentsJSON: #"{"filter":{"kind":"swift"}}"#
    )

    #expect(throws: FoundationModelsAgentEvaluationsError.self) {
      _ = try step.exactToolExpectation()
    }
  }

  @Test("Creates ModelSample and ModelSubject with native structured transcript")
  func sampleAndSubject() throws {
    let trajectory = FoundationModelsAgentTrajectory(
      finalStatus: .completed,
      steps: []
    )
    let fixture = FoundationModelsAgentTrajectoryFixture(
      name: "destination-only",
      expectedDestination: "expected answer",
      trajectory: trajectory
    )
    let sample = try fixture.modelSample(prompt: "Answer")
    let transcript = Transcript(entries: [
      .response(
        Transcript.Response(
          id: "response",
          metadata: [:],
          segments: [.text(.init(id: "text", content: "actual answer"))]
        )
      )
    ])
    let subject = ModelSubject(
      foundationModelsAgentValue: "actual answer",
      transcript: transcript
    )

    #expect(sample.expected == "expected answer")
    #expect(sample.expectations != nil)
    #expect(subject.value == "actual answer")
    #expect(subject.transcript?.responses.count == 1)
  }

  @Test("ToolCallEvaluator reports a disallowed native call")
  func disallowedNativeCall() async throws {
    let trajectory = FoundationModelsAgentTrajectory(
      finalStatus: .completed,
      steps: []
    )
    let expectation = try TrajectoryExpectation(
      foundationModelsAgentTrajectory: trajectory,
      disallowedToolNames: ["delete"]
    )
    let sample = ModelSample(
      prompt: "Read only",
      expected: "not deleted",
      expectations: expectation
    )
    let call = Transcript.ToolCall(
      id: "delete-call",
      toolName: "delete",
      arguments: GeneratedContent(properties: ["record_id": "123"])
    )
    let subject = ModelSubject(
      foundationModelsAgentValue: "not deleted",
      transcript: Transcript(entries: [
        .toolCalls(Transcript.ToolCalls(id: "delete-group", [call]))
      ])
    )
    let evaluator = ToolCallEvaluator<ModelSample<String>>(
      foundationModelsAgentMetricPrefix: "safety_path"
    )

    let metrics = try await evaluator.metrics(subject: subject, input: sample)

    #expect(metrics[evaluator.allPass]?.value == .failing)
  }

  @Test("Xcode 27 helper surface compiles with typed evaluator metrics")
  func availabilityCompilation() {
    let evaluator = ToolCallEvaluator<ModelSample<String>>(
      foundationModelsAgentMetricPrefix: "compile_check"
    )

    #expect(evaluator.allPass.name == "compile_check_all_pass")
    #expect(evaluator.percentagePass.name == "compile_check_percentage_pass")
  }
}

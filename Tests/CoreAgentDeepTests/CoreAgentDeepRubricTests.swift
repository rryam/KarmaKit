import CoreAgent
import CoreAgentDeep
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentDeep rubric middleware")
struct CoreAgentDeepRubricTests {
  @Test("Rubric middleware is a no-op when rubric is empty")
  func rubricMiddlewareIsNoOpWhenRubricIsEmpty() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(text: "final answer")
    ])
    let session = try CoreAgentSession(model: model)
    let middleware = CoreAgentDeepRubricMiddleware(
      grader: ClosureCoreAgentDeepRubricGrader { _, _, _ in
        Issue.record("grader should not run without a rubric")
        return CoreAgentDeepRubricEvaluation(
          verdict: .satisfied,
          iteration: 1,
          criteria: [],
          revisionMessage: nil
        )
      }
    )

    let result = try await middleware.respond(
      session: session,
      to: "Write the answer.",
      rubric: nil
    )

    #expect(result.status == .satisfied)
    #expect(result.content == "final answer")
    #expect(result.evaluations.isEmpty)
    #expect(result.iterationCount == 1)
  }

  @Test("Rubric middleware stops when grader is satisfied")
  func rubricMiddlewareStopsWhenGraderIsSatisfied() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(text: "includes required token")
    ])
    let session = try CoreAgentSession(model: model)
    let middleware = CoreAgentDeepRubricMiddleware(
      grader: ClosureCoreAgentDeepRubricGrader { _, responseText, _ in
        if responseText.contains("required token") {
          return CoreAgentDeepRubricEvaluation(
            verdict: .satisfied,
            iteration: 1,
            criteria: [
              CoreAgentDeepRubricCriterionFeedback(
                criterion: "mentions required token",
                passed: true,
                feedback: nil
              )
            ],
            revisionMessage: nil
          )
        }
        return CoreAgentDeepRubricEvaluation(
          verdict: .needsRevision,
          iteration: 1,
          criteria: [],
          revisionMessage: "Add the required token."
        )
      }
    )

    let result = try await middleware.respond(
      session: session,
      to: "Write the answer.",
      rubric: "Must mention required token."
    )

    #expect(result.status == .satisfied)
    #expect(result.evaluations.count == 1)
    #expect(result.evaluations[0].verdict == .satisfied)
    #expect(result.iterationCount == 1)
  }

  @Test("Rubric middleware injects revision feedback and retries")
  func rubricMiddlewareInjectsRevisionFeedbackAndRetries() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(text: "draft"),
      .response(text: "draft includes required token"),
    ])
    let session = try CoreAgentSession(model: model)
    let gradingCounter = GradingCallCounter()
    let middleware = CoreAgentDeepRubricMiddleware(
      grader: ClosureCoreAgentDeepRubricGrader { _, responseText, iteration in
        await gradingCounter.increment()
        if responseText.contains("required token") {
          return CoreAgentDeepRubricEvaluation(
            verdict: .satisfied,
            iteration: iteration,
            criteria: [],
            revisionMessage: nil
          )
        }
        return CoreAgentDeepRubricEvaluation(
          verdict: .needsRevision,
          iteration: iteration,
          criteria: [
            CoreAgentDeepRubricCriterionFeedback(
              criterion: "mentions required token",
              passed: false,
              feedback: "Add the required token."
            )
          ],
          revisionMessage: "Add the required token."
        )
      },
      maxIterations: 3
    )

    let result = try await middleware.respond(
      session: session,
      to: "Write the answer.",
      rubric: "Must mention required token."
    )

    #expect(await gradingCounter.value == 2)
    #expect(result.status == .satisfied)
    #expect(result.iterationCount == 2)
    #expect(result.evaluations.count == 2)
    #expect(result.evaluations[0].verdict == .needsRevision)
    #expect(result.evaluations[1].verdict == .satisfied)
    let transcripts = model.recorder.capturedTranscripts()
    #expect(transcripts.count == 2)
    #expect(transcripts[1].containsText(CoreAgentDeepRubricMiddleware.revisionMarker))
    #expect(transcripts[1].containsText("Add the required token."))
  }

  @Test("Rubric middleware stops at max iterations")
  func rubricMiddlewareStopsAtMaxIterations() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(text: "still wrong"),
      .response(text: "still wrong"),
    ])
    let session = try CoreAgentSession(model: model)
    let middleware = CoreAgentDeepRubricMiddleware(
      grader: ClosureCoreAgentDeepRubricGrader { _, _, iteration in
        CoreAgentDeepRubricEvaluation(
          verdict: .needsRevision,
          iteration: iteration,
          criteria: [],
          revisionMessage: "Try again."
        )
      },
      maxIterations: 2
    )

    let result = try await middleware.respond(
      session: session,
      to: "Write the answer.",
      rubric: "Must be correct."
    )

    #expect(result.status == .maxIterationsReached)
    #expect(result.iterationCount == 2)
    #expect(result.evaluations.count == 2)
    #expect(result.evaluations.allSatisfy { $0.verdict == .needsRevision })
  }

  @Test("Rubric middleware fails closed on grader errors")
  func rubricMiddlewareFailsClosedOnGraderErrors() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(text: "answer")
    ])
    let session = try CoreAgentSession(model: model)
    let middleware = CoreAgentDeepRubricMiddleware(
      grader: ClosureCoreAgentDeepRubricGrader { _, _, _ in
        throw CoreAgentDeepRubricError.graderFailed("boom")
      }
    )

    let result = try await middleware.respond(
      session: session,
      to: "Write the answer.",
      rubric: "Must be correct."
    )

    #expect(result.status == .graderError)
    #expect(result.evaluations.count == 1)
    #expect(result.evaluations[0].verdict == .graderError)
  }
}

extension Transcript {
  fileprivate func containsText(_ expected: String) -> Bool {
    contains { entry in
      switch entry {
      case .instructions(let instructions):
        instructions.segments.containsText(expected)
      case .prompt(let prompt):
        prompt.segments.containsText(expected)
      case .toolOutput(let output):
        output.segments.containsText(expected)
      case .response(let response):
        response.segments.containsText(expected)
      case .reasoning(let reasoning):
        reasoning.segments.containsText(expected)
      case .toolCalls:
        false
      @unknown default:
        false
      }
    }
  }
}

extension [Transcript.Segment] {
  fileprivate func containsText(_ expected: String) -> Bool {
    contains { segment in
      if case .text(let text) = segment {
        return text.content.contains(expected)
      }
      return false
    }
  }
}

private actor GradingCallCounter {
  private var count = 0

  var value: Int { count }

  func increment() {
    count += 1
  }

  @Test("FoundationModels rubric grader maps structured verdicts")
  func foundationModelsRubricGraderMapsStructuredVerdict() async throws {
    let model = RecordedLanguageModel(steps: [
      .response(
        text: """
          {
            "verdict": "needsRevision",
            "criteria": [
              {
                "criterion": "mentions required token",
                "passed": false,
                "feedback": "Add the required token."
              }
            ],
            "revisionMessage": "Add the required token."
          }
          """)
    ])
    let session = try CoreAgentSession(model: model)
    let grader = CoreAgentDeepFoundationModelsRubricGrader(session: session)
    let run = CoreAgentRun(
      id: UUID(),
      startedAt: Date(),
      endedAt: Date(),
      usage: nil,
      events: []
    )
    let evaluation = try await grader.grade(
      CoreAgentDeepRubricGradeRequest(
        rubric: "Must mention required token.",
        run: run,
        responseText: "draft",
        iteration: 1
      )
    )
    #expect(evaluation.verdict == .needsRevision)
    #expect(evaluation.criteria.count == 1)
    #expect(evaluation.criteria[0].passed == false)
  }

}

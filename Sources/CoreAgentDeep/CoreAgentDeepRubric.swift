import CoreAgent
import Foundation
import FoundationModels

public enum CoreAgentDeepRubricVerdict: String, Codable, Equatable, Sendable {
  case satisfied
  case needsRevision
  case failed
  case graderError
}

public enum CoreAgentDeepRubricCompletionStatus: String, Codable, Equatable, Sendable {
  case satisfied
  case maxIterationsReached
  case failed
  case graderError
}

public struct CoreAgentDeepRubricCriterionFeedback: Codable, Equatable, Sendable {
  public let criterion: String
  public let passed: Bool
  public let feedback: String?

  public init(criterion: String, passed: Bool, feedback: String?) {
    self.criterion = criterion
    self.passed = passed
    self.feedback = feedback
  }
}

public struct CoreAgentDeepRubricEvaluation: Codable, Equatable, Sendable {
  public let verdict: CoreAgentDeepRubricVerdict
  public let iteration: Int
  public let criteria: [CoreAgentDeepRubricCriterionFeedback]
  public let revisionMessage: String?

  public init(
    verdict: CoreAgentDeepRubricVerdict,
    iteration: Int,
    criteria: [CoreAgentDeepRubricCriterionFeedback],
    revisionMessage: String?
  ) {
    self.verdict = verdict
    self.iteration = iteration
    self.criteria = criteria
    self.revisionMessage = revisionMessage
  }
}

public enum CoreAgentDeepRubricError: Error, Equatable, Sendable {
  case emptyRubric
  case graderFailed(String)
  case invalidMaxIterations(Int)
}

public struct CoreAgentDeepRubricGradeRequest: Sendable {
  public let rubric: String
  public let run: CoreAgentRun
  public let responseText: String
  public let iteration: Int

  public init(
    rubric: String,
    run: CoreAgentRun,
    responseText: String,
    iteration: Int
  ) {
    self.rubric = rubric
    self.run = run
    self.responseText = responseText
    self.iteration = iteration
  }
}

public protocol CoreAgentDeepRubricGrader: Sendable {
  func grade(_ request: CoreAgentDeepRubricGradeRequest) async throws
    -> CoreAgentDeepRubricEvaluation
}

public struct ClosureCoreAgentDeepRubricGrader: CoreAgentDeepRubricGrader {
  private let handler:
    @Sendable (
      CoreAgentDeepRubricGradeRequest,
      String,
      Int
    ) async throws -> CoreAgentDeepRubricEvaluation

  public init(
    _ handler:
      @escaping @Sendable (
        CoreAgentDeepRubricGradeRequest,
        String,
        Int
      ) async throws -> CoreAgentDeepRubricEvaluation
  ) {
    self.handler = handler
  }

  public func grade(_ request: CoreAgentDeepRubricGradeRequest) async throws
    -> CoreAgentDeepRubricEvaluation
  {
    try await handler(request, request.responseText, request.iteration)
  }
}

public struct CoreAgentDeepRubricResult: Sendable {
  public let content: String
  public let run: CoreAgentRun
  public let evaluations: [CoreAgentDeepRubricEvaluation]
  public let status: CoreAgentDeepRubricCompletionStatus
  public let iterationCount: Int

  public init(
    content: String,
    run: CoreAgentRun,
    evaluations: [CoreAgentDeepRubricEvaluation],
    status: CoreAgentDeepRubricCompletionStatus,
    iterationCount: Int
  ) {
    self.content = content
    self.run = run
    self.evaluations = evaluations
    self.status = status
    self.iterationCount = iterationCount
  }
}

public struct CoreAgentDeepRubricMiddleware: Sendable {
  public static let revisionMarker = "COREAGENT_DEEP_RUBRIC_REVISION_V1"

  public let grader: any CoreAgentDeepRubricGrader
  public let maxIterations: Int

  public init(
    grader: any CoreAgentDeepRubricGrader,
    maxIterations: Int = 3
  ) {
    self.grader = grader
    self.maxIterations = max(1, maxIterations)
  }

  public func respond(
    session: CoreAgentSession,
    to prompt: String,
    rubric: String?,
    options: GenerationOptions = GenerationOptions(),
    contextOptions: ContextOptions = ContextOptions(),
    metadata: CoreAgentRequestMetadata = [:]
  ) async throws -> CoreAgentDeepRubricResult {
    let trimmedRubric = rubric?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmedRubric.isEmpty {
      let response = try await session.respond(
        to: prompt,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
      return CoreAgentDeepRubricResult(
        content: response.content,
        run: response.run,
        evaluations: [],
        status: .satisfied,
        iterationCount: 1
      )
    }

    var evaluations: [CoreAgentDeepRubricEvaluation] = []
    var currentPrompt = prompt
    var latestResponse: CoreAgentResponse<String>?

    for iteration in 1...maxIterations {
      let response = try await session.respond(
        to: currentPrompt,
        options: options,
        contextOptions: contextOptions,
        metadata: metadata
      )
      latestResponse = response

      let evaluation: CoreAgentDeepRubricEvaluation
      do {
        evaluation = try await grader.grade(
          CoreAgentDeepRubricGradeRequest(
            rubric: trimmedRubric,
            run: response.run,
            responseText: response.content,
            iteration: iteration
          )
        )
      } catch {
        let failedEvaluation = CoreAgentDeepRubricEvaluation(
          verdict: .graderError,
          iteration: iteration,
          criteria: [],
          revisionMessage: String(describing: error)
        )
        evaluations.append(failedEvaluation)
        return CoreAgentDeepRubricResult(
          content: response.content,
          run: response.run,
          evaluations: evaluations,
          status: .graderError,
          iterationCount: iteration
        )
      }

      evaluations.append(evaluation)

      switch evaluation.verdict {
      case .satisfied:
        return CoreAgentDeepRubricResult(
          content: response.content,
          run: response.run,
          evaluations: evaluations,
          status: .satisfied,
          iterationCount: iteration
        )
      case .failed:
        return CoreAgentDeepRubricResult(
          content: response.content,
          run: response.run,
          evaluations: evaluations,
          status: .failed,
          iterationCount: iteration
        )
      case .graderError:
        return CoreAgentDeepRubricResult(
          content: response.content,
          run: response.run,
          evaluations: evaluations,
          status: .graderError,
          iterationCount: iteration
        )
      case .needsRevision:
        if iteration == maxIterations {
          return CoreAgentDeepRubricResult(
            content: response.content,
            run: response.run,
            evaluations: evaluations,
            status: .maxIterationsReached,
            iterationCount: iteration
          )
        }
        currentPrompt = Self.revisionPrompt(
          originalPrompt: prompt,
          revisionMessage: evaluation.revisionMessage ?? defaultRevisionMessage(
            criteria: evaluation.criteria
          )
        )
      }
    }

    let response = latestResponse!
    return CoreAgentDeepRubricResult(
      content: response.content,
      run: response.run,
      evaluations: evaluations,
      status: .maxIterationsReached,
      iterationCount: maxIterations
    )
  }

  public static func revisionPrompt(
    originalPrompt: String,
    revisionMessage: String
  ) -> String {
    """
    \(originalPrompt)

    \(revisionMarker)
    The previous response did not satisfy the rubric.

    \(revisionMessage)

    Revise your work to satisfy the rubric.
    """
  }

  private func defaultRevisionMessage(
    criteria: [CoreAgentDeepRubricCriterionFeedback]
  ) -> String {
    let lines = criteria
      .filter { !$0.passed }
      .map { feedback in
        if let detail = feedback.feedback, !detail.isEmpty {
          return "- \(feedback.criterion): \(detail)"
        }
        return "- \(feedback.criterion)"
      }
    if lines.isEmpty {
      return "Revise the previous response to satisfy the rubric."
    }
    return "Rubric feedback:\n" + lines.joined(separator: "\n")
  }
}

@Generable
private struct CoreAgentDeepFoundationModelsRubricCriterionDraft: Sendable {
  let criterion: String
  let passed: Bool
  let feedback: String?
}

@Generable
private struct CoreAgentDeepFoundationModelsRubricEnvelope: Sendable {
  let verdict: String
  let criteria: [CoreAgentDeepFoundationModelsRubricCriterionDraft]
  let revisionMessage: String?
}

public struct CoreAgentDeepFoundationModelsRubricGrader: CoreAgentDeepRubricGrader {
  private let session: CoreAgentSession
  private let graderInstructions: String?

  public init(session: CoreAgentSession, graderInstructions: String? = nil) {
    self.session = session
    self.graderInstructions = graderInstructions
  }

  public func grade(_ request: CoreAgentDeepRubricGradeRequest) async throws
    -> CoreAgentDeepRubricEvaluation
  {
    let response = try await session.respond(
      to: Self.prompt(for: request, instructions: graderInstructions),
      generating: CoreAgentDeepFoundationModelsRubricEnvelope.self
    )
    return try Self.evaluation(from: response.content, iteration: request.iteration)
  }

  private static func prompt(for request: CoreAgentDeepRubricGradeRequest, instructions: String?) -> String {
    let baseInstructions = """
      Grade the candidate response against the rubric using structured output only.
      Supported verdict literals: satisfied, needsRevision, failed.
      Return one criterion entry per rubric requirement you evaluated.
      """
    let extra = instructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let instructionsBlock = extra.isEmpty ? baseInstructions : baseInstructions + "\n\n" + extra
    return """
      \(instructionsBlock)

      Rubric:
      \(request.rubric)

      Candidate response:
      \(request.responseText)

      Iteration: \(request.iteration)
      """
  }

  private static func evaluation(
    from envelope: CoreAgentDeepFoundationModelsRubricEnvelope,
    iteration: Int
  ) throws -> CoreAgentDeepRubricEvaluation {
    let verdict = try verdict(from: envelope.verdict)
    let criteria = envelope.criteria.map {
      CoreAgentDeepRubricCriterionFeedback(
        criterion: $0.criterion.trimmingCharacters(in: .whitespacesAndNewlines),
        passed: $0.passed,
        feedback: $0.feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }.filter { !$0.criterion.isEmpty }
    let revision = envelope.revisionMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
    return CoreAgentDeepRubricEvaluation(
      verdict: verdict,
      iteration: iteration,
      criteria: criteria,
      revisionMessage: revision?.isEmpty == false ? revision : nil
    )
  }

  private static func verdict(from raw: String) throws -> CoreAgentDeepRubricVerdict {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "satisfied", "pass", "passed":
      return .satisfied
    case "needsrevision", "needs_revision", "revise", "revision":
      return .needsRevision
    case "failed", "fail":
      return .failed
    default:
      throw CoreAgentDeepRubricError.graderFailed("unsupported rubric verdict: \(raw)")
    }
  }
}

import Foundation
import FoundationModelsAgent
import FoundationModelsAgentTestSupport
import Testing

private let routingDecisionDate = Date(timeIntervalSince1970: 1_750_000_000)

private func routingCandidate(
  id: String,
  steps: [RecordedLanguageModelStep] = [],
  availability: FoundationModelsAgentRouteAvailabilityState = .available,
  quota: FoundationModelsAgentRouteQuotaState = .notApplicable,
  privacy: FoundationModelsAgentRoutePrivacyClass = .onDevice,
  network: FoundationModelsAgentRouteNetworkClass = .none,
  contextTokens: Int = 8_192,
  reasoning: FoundationModelsAgentRouteReasoningSupport = .supported
) -> FoundationModelsAgentRouteCandidate {
  let model = RecordedLanguageModel(
    steps: steps.isEmpty ? [.response(text: id)] : steps
  )
  return FoundationModelsAgentRouteCandidate(
    model: model,
    descriptor: FoundationModelsAgentRouteDescriptor(
      id: FoundationModelsAgentRouteID(id),
      purpose: "Deterministic \(id) test route.",
      declaredCapabilities: [.guidedGeneration, .reasoning, .toolCalling],
      availability: .init(
        observedAt: routingDecisionDate,
        state: availability,
        quota: quota
      ),
      privacyClass: privacy,
      networkClass: network,
      contextSize: .known(tokenLimit: contextTokens),
      reasoningSupport: reasoning,
      accountingProvenance: privacy == .onDevice
        ? .none
        : .externalProvider(providerID: "fixture", accountReference: "test-account")
    )
  )
}

private func routingPolicy(
  primary: String,
  fallbacks: [String] = []
) -> ClosureFoundationModelsAgentRoutingPolicy {
  ClosureFoundationModelsAgentRoutingPolicy { _, _ in
    FoundationModelsAgentRoutePlan(
      primaryRouteID: FoundationModelsAgentRouteID(primary),
      fallbackRouteIDs: fallbacks.map { FoundationModelsAgentRouteID($0) }
    )
  }
}

private func rejectionCodes(
  in decision: FoundationModelsAgentRouteDecision,
  routeID: String
) -> [FoundationModelsAgentRouteRejectionCode] {
  guard
    let candidate = decision.candidateDecisions.first(where: {
      $0.candidate.id == FoundationModelsAgentRouteID(routeID)
    }),
    case .rejected(let reasons) = candidate.outcome
  else {
    return []
  }
  return reasons.map(\.code)
}

@Suite("FoundationModelsAgent native model routing")
struct FoundationModelsAgentRoutingTests {
  @Test("Rejects an unavailable fake model before execution")
  func unavailableModel() {
    let result = FoundationModelsAgentRouter().select(
      from: [
        routingCandidate(
          id: "offline",
          availability: .unavailable(
            code: "fixture-offline",
            explanation: "The deterministic fixture is offline."
          )
        )
      ],
      policy: routingPolicy(primary: "offline"),
      decidedAt: routingDecisionDate
    )

    #expect(result.selection == nil)
    #expect(result.decision.selectedRouteID == nil)
    #expect(rejectionCodes(in: result.decision, routeID: "offline") == [.unavailable])
  }

  @Test("Default data policy denies a server route and records explicit local fallback")
  func privacyDenial() throws {
    let result = FoundationModelsAgentRouter().select(
      from: [
        routingCandidate(
          id: "server",
          privacy: .thirdPartyService,
          network: .publicInternet
        ),
        routingCandidate(id: "local"),
      ],
      policy: routingPolicy(primary: "server", fallbacks: ["local"]),
      decidedAt: routingDecisionDate
    )

    let selection = try #require(result.selection)
    #expect(selection.decision.selectedRouteID == FoundationModelsAgentRouteID("local"))
    #expect(selection.decision.selectedFallback)
    #expect(
      rejectionCodes(in: selection.decision, routeID: "server")
        == [.privacyDenied, .networkDenied]
    )
  }

  @Test("Rejects insufficient context and selects the declared fallback")
  func insufficientContext() throws {
    let result = FoundationModelsAgentRouter().select(
      from: [
        routingCandidate(id: "small", contextTokens: 2_048),
        routingCandidate(id: "large", contextTokens: 16_384),
      ],
      requirements: .init(minimumContextTokens: 8_000),
      policy: routingPolicy(primary: "small", fallbacks: ["large"]),
      decidedAt: routingDecisionDate
    )

    let selection = try #require(result.selection)
    #expect(selection.decision.selectedRouteID == FoundationModelsAgentRouteID("large"))
    #expect(
      rejectionCodes(in: selection.decision, routeID: "small") == [.insufficientContext]
    )
  }

  @Test("Treats a reported zero context size as a literal conservative boundary")
  func zeroContextBoundary() throws {
    let candidate = routingCandidate(id: "beta-zero", contextTokens: 0)

    let noMinimum = FoundationModelsAgentRouter().select(
      from: [candidate],
      policy: routingPolicy(primary: "beta-zero"),
      decidedAt: routingDecisionDate
    )
    #expect(try #require(noMinimum.selection).decision.selectedRouteID == "beta-zero")

    let zeroMinimum = FoundationModelsAgentRouter().select(
      from: [candidate],
      requirements: .init(minimumContextTokens: 0),
      policy: routingPolicy(primary: "beta-zero"),
      decidedAt: routingDecisionDate
    )
    #expect(try #require(zeroMinimum.selection).decision.selectedRouteID == "beta-zero")

    let positiveMinimum = FoundationModelsAgentRouter().select(
      from: [candidate],
      requirements: .init(minimumContextTokens: 1),
      policy: routingPolicy(primary: "beta-zero"),
      decidedAt: routingDecisionDate
    )
    #expect(positiveMinimum.selection == nil)
    #expect(
      rejectionCodes(in: positiveMinimum.decision, routeID: "beta-zero")
        == [.insufficientContext]
    )
  }

  @Test("Distinguishes approaching and reached quota states")
  func quotaStates() throws {
    let requirements = FoundationModelsAgentRouteRequirements(
      quotaPolicy: .avoidApproachingLimit
    )
    let result = FoundationModelsAgentRouter().select(
      from: [
        routingCandidate(id: "approaching", quota: .approachingLimit),
        routingCandidate(
          id: "reached",
          quota: .limitReached(
            resetDate: Date(timeIntervalSince1970: 1_750_003_600),
            canRequestLimitIncrease: true
          )
        ),
        routingCandidate(id: "comfortable", quota: .belowLimit),
      ],
      requirements: requirements,
      policy: routingPolicy(
        primary: "approaching",
        fallbacks: ["reached", "comfortable"]
      ),
      decidedAt: routingDecisionDate
    )

    let selection = try #require(result.selection)
    #expect(selection.decision.selectedRouteID == FoundationModelsAgentRouteID("comfortable"))
    #expect(
      rejectionCodes(in: selection.decision, routeID: "approaching")
        == [.quotaApproachingLimit]
    )
    #expect(
      rejectionCodes(in: selection.decision, routeID: "reached") == [.quotaLimitReached]
    )
  }

  @Test("Follows app fallback order and records every rejection")
  func fallbackOrdering() throws {
    let unavailable = FoundationModelsAgentRouteAvailabilityState.unavailable(
      code: "fixture-unavailable",
      explanation: "Unavailable for deterministic routing."
    )
    let result = FoundationModelsAgentRouter().select(
      from: [
        routingCandidate(id: "primary", availability: unavailable),
        routingCandidate(id: "fallback-one", availability: unavailable),
        routingCandidate(id: "fallback-two"),
        routingCandidate(id: "not-planned"),
      ],
      policy: routingPolicy(
        primary: "primary",
        fallbacks: ["fallback-one", "fallback-two"]
      ),
      decidedAt: routingDecisionDate
    )

    let selection = try #require(result.selection)
    #expect(selection.decision.selectedRouteID == FoundationModelsAgentRouteID("fallback-two"))
    #expect(rejectionCodes(in: selection.decision, routeID: "primary") == [.unavailable])
    #expect(
      rejectionCodes(in: selection.decision, routeID: "fallback-one") == [.unavailable]
    )
    #expect(
      rejectionCodes(in: selection.decision, routeID: "not-planned") == [.notIncludedInPlan]
    )
  }

  @Test("Does not infer fallback from an eligible unplanned candidate")
  func noImplicitFallback() {
    let result = FoundationModelsAgentRouter().select(
      from: [
        routingCandidate(
          id: "primary",
          availability: .unavailable(
            code: "fixture-unavailable",
            explanation: "The primary route is unavailable."
          )
        ),
        routingCandidate(id: "server"),
      ],
      policy: routingPolicy(primary: "primary"),
      decidedAt: routingDecisionDate
    )

    #expect(result.selection == nil)
    #expect(rejectionCodes(in: result.decision, routeID: "primary") == [.unavailable])
    #expect(rejectionCodes(in: result.decision, routeID: "server") == [.notIncludedInPlan])
  }

  @Test("Serializes deterministic decision evidence")
  func evidenceSerialization() throws {
    let result = FoundationModelsAgentRouter().select(
      from: [
        routingCandidate(id: "first"),
        routingCandidate(id: "second"),
      ],
      policy: routingPolicy(primary: "first", fallbacks: ["second"]),
      decidedAt: routingDecisionDate
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]

    let first = try encoder.encode(result.decision)
    let second = try encoder.encode(result.decision)
    #expect(first == second)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let decoded = try decoder.decode(FoundationModelsAgentRouteDecision.self, from: first)
    #expect(decoded == result.decision)
  }

  @Test("Records route provenance and usage before and after a completed run")
  func completedRunProvenance() async throws {
    let result = FoundationModelsAgentRouter().select(
      from: [
        routingCandidate(
          id: "local",
          steps: [.response(text: "routed", inputTokens: 7, outputTokens: 3)]
        )
      ],
      policy: routingPolicy(primary: "local"),
      decidedAt: routingDecisionDate
    )
    let selection = try #require(result.selection)
    let session = try AgentSession(
      model: selection.model,
      routingDecision: selection.decision
    )

    let response = try await session.respond(to: "Use the selected route.")

    #expect(response.content == "routed")
    #expect(response.run.routingDecision == selection.decision)
    #expect(response.run.usage?.inputTokens == 7)
    let selectedIndex = try #require(
      response.run.events.firstIndex(where: { $0.kind == .routeSelected })
    )
    let attemptIndex = try #require(
      response.run.events.firstIndex(where: { $0.kind == .modelAttemptStarted })
    )
    #expect(selectedIndex < attemptIndex)
    #expect(response.run.events.last?.attributes["route_id"] == "local")
  }

  @Test("Keeps route provenance on a failed run without inventing usage")
  func failedRunProvenance() async throws {
    let result = FoundationModelsAgentRouter().select(
      from: [
        routingCandidate(id: "failing", steps: [.failure("intentional")])
      ],
      policy: routingPolicy(primary: "failing"),
      decidedAt: routingDecisionDate
    )
    let selection = try #require(result.selection)
    let session = try AgentSession(
      model: selection.model,
      routingDecision: selection.decision
    )

    await #expect(throws: RecordedLanguageModelError.self) {
      try await session.respond(to: "Fail truthfully.")
    }
    let run = try #require(await session.lastRun())
    #expect(run.routingDecision == selection.decision)
    #expect(run.usage == nil)
    #expect(run.events.last?.kind == .runFailed)
    #expect(run.events.last?.attributes["route_id"] == "failing")
  }

  @Test("Rejects manually inconsistent route evidence")
  func invalidDecision() {
    let candidate = routingCandidate(id: "candidate")
    let plan = FoundationModelsAgentRoutePlan(primaryRouteID: "candidate")
    let invalid = FoundationModelsAgentRouteDecision(
      decidedAt: routingDecisionDate,
      requirements: .init(),
      plan: plan,
      selectedRouteID: "candidate",
      selectedFallback: false,
      candidateDecisions: [
        .init(
          candidate: candidate.descriptor,
          outcome: .rejected(
            reasons: [
              .init(code: .unavailable, explanation: "Contradicts selectedRouteID.")
            ]
          )
        )
      ]
    )

    #expect(throws: FoundationModelsAgentError.self) {
      try AgentSession(model: candidate.model, routingDecision: invalid)
    }
  }
}

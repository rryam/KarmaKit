import CoreAgent
import CoreAgentEngine
import CoreAgentGraph
import CoreAgentTestSupport
import Foundation
import FoundationModels
import SwiftData
import Testing

@testable import CoreAgentApplePlatform

extension CoreAgentApplePlatformTests {
  @MainActor
  @Test("SwiftData graph store fails closed on forged scope keys before read or mutation")
  func swiftDataGraphStoreFailsClosedOnForgedScopeKeysBeforeReadOrMutation() async throws {
    let context = try Self.swiftDataGraphContext()
    let store: any CoreAgentGraphStore<GraphValue> =
      CoreAgentSwiftDataGraphStore<GraphValue>(modelContext: context)

    try await store.put(GraphValue(label: "stable"), forKey: "profile", namespace: "alpha")
    context.insert(
      CoreAgentSwiftDataGraphStoreRecord(
        namespace: "alpha",
        key: "profile",
        updatedAt: Date(timeIntervalSince1970: 4_102_444_800),
        storeScopeKey: "graph-store-scope-sha256-v1:forged",
        encodedValue: Data("not-json".utf8),
        valueDigest: "sha256:corrupt"
      ))
    try context.save()

    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await store.record(forKey: "profile", namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      _ = try await store.keys(namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      try await store.put(GraphValue(label: "replacement"), forKey: "profile", namespace: "alpha")
    }
    await #expect(throws: CoreAgentSwiftDataGraphPersistenceError.self) {
      try await store.removeValue(forKey: "profile", namespace: "alpha")
    }
  }

  @MainActor
  @Test("SwiftUI projection store summarizes run state without raw event payloads")
  func swiftUIProjectionStoreSummarizesRunStateWithoutRawEventPayloads() throws {
    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    let run = CoreAgentRun(
      id: runID,
      startedAt: Date(timeIntervalSince1970: 1_800_000_000),
      endedAt: Date(timeIntervalSince1970: 1_800_000_003),
      usage: nil,
      events: [
        Self.event(runID: runID, kind: .runStarted, message: "contains token=secret"),
        Self.event(
          runID: runID,
          kind: .runFailed,
          message: "failed with token=secret",
          attributes: ["api_key": "secret", "tool": "write_file"]
        ),
      ]
    )
    let trace = try CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-a",
      run: run,
      receipt: CoreAgentRunReceipt(run: run),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_004)
    )

    let store = CoreAgentRunProjectionStore()
    store.apply(traces: [trace, trace])
    let projection = try #require(store.projections.first)

    #expect(store.projections.count == 1)
    #expect(projection.runID == runID)
    #expect(projection.projectID == "coreagent")
    #expect(projection.threadID == "thread-a")
    #expect(projection.status == .failed)
    #expect(projection.lastEventKind == .runFailed)
    #expect(projection.eventCounts[.runStarted] == 1)
    #expect(projection.eventCounts[.runFailed] == 1)
    #expect(projection.duration == 3)

    let secondRunID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
    let secondRun = CoreAgentRun(
      id: secondRunID,
      startedAt: Date(timeIntervalSince1970: 1_800_000_010),
      endedAt: Date(timeIntervalSince1970: 1_800_000_010),
      usage: nil,
      events: [Self.event(runID: secondRunID, kind: .runStarted, message: "started")]
    )
    let secondTrace = try CoreAgentEngineTrace(
      projectID: "coreagent",
      threadID: "thread-b",
      run: secondRun,
      receipt: CoreAgentRunReceipt(run: secondRun),
      ingestedAt: Date(timeIntervalSince1970: 1_800_000_011)
    )

    store.apply(traces: [secondTrace])

    #expect(store.projections.map(\.runID) == [runID, secondRunID])
    #expect(store.projections.last?.status == .running)
  }

  static func checkpoint(
    savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> CoreAgentCheckpoint {
    CoreAgentCheckpoint(
      savedAt: savedAt,
      compatibilityRevision: "revision-a",
      transcript: Transcript(entries: [
        .prompt(.init(segments: [.text(.init(content: "persisted"))]))
      ])
    )
  }

  static func event(
    runID: UUID,
    kind: CoreAgentEventKind,
    message: String,
    attributes: [String: String] = [:]
  ) -> CoreAgentEvent {
    CoreAgentEvent(
      id: UUID(),
      runID: runID,
      timestamp: Date(timeIntervalSince1970: 1_800_000_000),
      kind: kind,
      message: message,
      attributes: attributes
    )
  }

  static func engineRun(
    id: UUID,
    events: [CoreAgentEvent] = []
  ) -> CoreAgentRun {
    let storedEvents =
      events.isEmpty
      ? [event(runID: id, kind: .runCompleted, message: "Run completed.")]
      : events
    return CoreAgentRun(
      id: id,
      startedAt: Date(timeIntervalSince1970: 1),
      endedAt: Date(timeIntervalSince1970: 2),
      usage: CoreAgentUsage(
        inputTokens: 10,
        cachedInputTokens: 2,
        outputTokens: 4,
        reasoningTokens: 1
      ),
      events: storedEvents
    )
  }

  static func engineTraceData(_ trace: CoreAgentEngineTrace) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(trace)
  }

  static func engineIssueData(_ issue: CoreAgentEngineIssue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .deferredToDate
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(issue)
  }

  static func engineTraceRecord(
    _ trace: CoreAgentEngineTrace,
    sequence: Int = 0,
    traceScopeKey: String? = nil,
    redactionPolicyIdentifier: String = CoreAgentEngineRedactionPolicy.standard.identifier
  ) throws -> CoreAgentSwiftDataEngineTraceRecord {
    let encodedTrace = try engineTraceData(trace)
    return CoreAgentSwiftDataEngineTraceRecord(
      projectID: trace.projectID,
      threadID: trace.threadID,
      runID: trace.run.id,
      startedAt: trace.run.startedAt,
      endedAt: trace.run.endedAt,
      ingestedAt: trace.ingestedAt,
      sequence: sequence,
      traceScopeKey: traceScopeKey,
      redactionPolicyIdentifier: redactionPolicyIdentifier,
      encodedTrace: encodedTrace,
      traceDigest: CoreAgentSwiftDataEngineTraceRecord.integrityDigest(
        traceScopeKey: traceScopeKey,
        projectID: trace.projectID,
        threadID: trace.threadID,
        runID: trace.run.id,
        startedAt: trace.run.startedAt,
        endedAt: trace.run.endedAt,
        ingestedAt: trace.ingestedAt,
        redactionPolicyIdentifier: redactionPolicyIdentifier,
        encodedTrace: encodedTrace
      )
    )
  }

  static func engineIssueRecord(
    _ issue: CoreAgentEngineIssue,
    fingerprint: String? = nil,
    statusRawValue: String? = nil,
    issueDigest: String? = nil
  ) throws -> CoreAgentSwiftDataEngineIssueRecord {
    let encodedIssue = try engineIssueData(issue)
    let sidecarFingerprint = fingerprint ?? issue.fingerprint
    let sidecarStatus = statusRawValue ?? issue.status.rawValue
    let digest =
      issueDigest
      ?? CoreAgentSwiftDataEngineIssueRecord.integrityDigest(
        issueID: issue.id,
        projectID: issue.projectID,
        fingerprint: sidecarFingerprint,
        statusRawValue: sidecarStatus,
        firstSeenAt: issue.firstSeenAt,
        lastSeenAt: issue.lastSeenAt,
        encodedIssue: encodedIssue
      )
    return CoreAgentSwiftDataEngineIssueRecord(
      issueID: issue.id,
      projectID: issue.projectID,
      fingerprint: sidecarFingerprint,
      statusRawValue: sidecarStatus,
      firstSeenAt: issue.firstSeenAt,
      lastSeenAt: issue.lastSeenAt,
      encodedIssue: encodedIssue,
      issueDigest: digest
    )
  }

  static func engineFailedRun(
    id: UUID,
    errorType: String,
    tool: String
  ) -> CoreAgentRun {
    engineRun(
      id: id,
      events: [
        event(
          runID: id,
          kind: .toolExecutionFailed,
          message: "Tool failed.",
          attributes: [
            "error_type": errorType,
            "tool": tool,
          ]
        ),
        event(
          runID: id,
          kind: .runFailed,
          message: "Run failed.",
          attributes: [
            "error_type": errorType,
            "tool": tool,
          ]
        ),
      ]
    )
  }

  static func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", suffix))")!
  }

  struct ApplePlatformTestCustomSegment: Transcript.CustomSegment {
    struct Content: Codable, Equatable, Sendable {
      let value: String
    }

    let id: String
    let content: Content
  }

  struct GraphState: Codable, Equatable, Sendable {
    var log: [String] = []
  }

  struct GraphValue: Codable, Equatable, Sendable {
    var label: String
  }

  struct OtherGraphValue: Codable, Equatable, Sendable {
    var count: Int
  }

  actor AsyncTestSignal {
    private var hasSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      if hasSignaled {
        return
      }
      await withCheckedContinuation { continuation in
        continuations.append(continuation)
      }
    }

    func signal() {
      hasSignaled = true
      let pending = continuations
      continuations.removeAll()
      for continuation in pending {
        continuation.resume()
      }
    }
  }

  actor ComputerUseRecorder {
    private(set) var planCount = 0
    private(set) var executeCount = 0

    func plan(
      _ request: CoreAgentAppleComputerUseRequest
    ) -> CoreAgentAppleComputerUsePlan {
      planCount += 1
      return CoreAgentAppleComputerUsePlan(
        steps: [
          .init(id: "inspect", summary: "Inspect target state for \(request.actionID)."),
          .init(id: "click", summary: "Perform requested action \(request.actionID)."),
        ],
        requiredEvidence: [.screenshotDigest]
      )
    }

    func execute(
      _ request: CoreAgentAppleComputerUseRequest,
      plan: CoreAgentAppleComputerUsePlan,
      capturedAt: Date
    ) -> [CoreAgentAppleComputerUseEvidence] {
      executeCount += 1
      return [
        CoreAgentAppleComputerUseEvidence(
          kind: .screenshotDigest,
          digest: CoreAgentApplePlatformTests.screenshotDigest,
          capturedAt: capturedAt
        )
      ]
    }
  }

  actor HelperCodeRecorder {
    private(set) var runCount = 0
    private(set) var lastRequest: CoreAgentAppleAuthorizedHelperCodeInterpreterRequest?

    func record(
      _ request: CoreAgentAppleAuthorizedHelperCodeInterpreterRequest
    ) -> Int {
      runCount += 1
      lastRequest = request
      return runCount
    }
  }

  static func computerUseBackend(
    recorder: ComputerUseRecorder
  ) -> CoreAgentAppleComputerUseBackend {
    CoreAgentAppleComputerUseBackend(
      plan: { request in
        await recorder.plan(request)
      },
      execute: { request, plan in
        await recorder.execute(
          request,
          plan: plan,
          capturedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
      }
    )
  }

  static func helperCodeBackend(
    recorder: HelperCodeRecorder,
    stdout: String
  ) -> CoreAgentAppleHelperCodeInterpreterBackend {
    CoreAgentAppleHelperCodeInterpreterBackend { request in
      _ = await recorder.record(request)
      return CoreAgentAppleHelperCodeInterpreterBackendResult(
        exitCode: 0,
        stdout: stdout,
        stderr: "",
        outputs: ["result": .string(stdout.trimmingCharacters(in: .whitespacesAndNewlines))]
      )
    }
  }

  static func readTaskDonationDescriptor() -> CoreAgentAppIntentDescriptor {
    CoreAgentAppIntentDescriptor(
      identifier: "CoreAgentReadTaskIntent",
      title: "Read Task",
      mutability: .readOnly,
      allowsAgentExecution: true,
      allowedExecutionTargets: [.foreground],
      supportedModes: [.app],
      donationPolicy: .donateAfterUserInitiatedAction,
      requiresAuthorization: false,
      requiresHITLForSensitiveOperations: false
    )
  }

  static func canonicalTestURL(_ url: URL) -> URL {
    url.resolvingSymlinksInPath().standardizedFileURL
  }

  @MainActor
  static func swiftDataContext() throws -> ModelContext {
    let container = try ModelContainer(
      for: CoreAgentSwiftDataCheckpointRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
  }

  @MainActor
  static func swiftDataEngineContext() throws -> ModelContext {
    let container = try ModelContainer(
      for: CoreAgentSwiftDataEngineTraceRecord.self,
      CoreAgentSwiftDataEngineIssueRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
  }

  @MainActor
  static func swiftDataGraphContext() throws -> ModelContext {
    let container = try ModelContainer(
      for: CoreAgentSwiftDataGraphCheckpointRecord.self,
      CoreAgentSwiftDataGraphStoreRecord.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
  }

  static func receipt(
    id: String,
    requirement: CoreAgentAppleConsentRequirement,
    expiresAt: Date? = nil
  ) -> CoreAgentAppleConsentReceipt {
    CoreAgentAppleConsentReceipt.issue(
      id: id,
      issuerID: Self.issuerID,
      requirement: requirement,
      signingKey: Self.signingKey,
      grantedAt: Self.grantedAt,
      expiresAt: expiresAt ?? .distantFuture
    )
  }

  static let issuerID = "coreagent.test.consent"
  static let signingKey = CoreAgentAppleConsentSigningKey(
    Data("coreagent-apple-platform-test-signing-key".utf8)
  )!
  static let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
  static let screenshotDigest = "sha256:" + String(repeating: "a", count: 64)

  @Test("Remote code interpreter fails closed without backend and enforces policy")
  func remoteCodeInterpreterFailsClosedWithoutBackendAndEnforcesPolicy() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_170)
    let endpoint = URL(string: "https://interpreter.example/run")!
    let allowedNetworkGate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.remoteCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-remote"),
        networkPolicy: .allowed,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 11
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let backendMissingInterpreter = CoreAgentAppleRemoteCodeInterpreter(
      actionGate: allowedNetworkGate,
      policy: CoreAgentAppleRemoteCodeInterpreterPolicy(allowedEndpointURLs: [endpoint]),
      clock: { now }
    )
    let request = CoreAgentAppleRemoteCodeInterpreterRequest(
      id: "remote-1",
      endpointURL: endpoint
    )
    let receipt = CoreAgentAppleConsentReceipt.issue(
      id: "remote-receipt",
      issuerID: Self.issuerID,
      requirement: backendMissingInterpreter.consentRequirement(for: request),
      signingKey: Self.signingKey,
      grantedAt: now.addingTimeInterval(-10),
      expiresAt: now.addingTimeInterval(60)
    )

    let denied = await backendMissingInterpreter.run(request, consent: .granted(receipt))

    let localOnlyGate = CoreAgentAppleActionGate(
      sandbox: CoreAgentAppleSandboxProfile(
        capabilities: [.remoteCodeInterpreter],
        workspaceRoot: URL(fileURLWithPath: "/tmp/coreagent-remote"),
        networkPolicy: .localOnly,
        authorityBoundaryID: "workspace:coreagent",
        policyVersion: 11
      ),
      trustedConsentIssuerID: Self.issuerID,
      consentSigningKey: Self.signingKey,
      now: { now }
    )
    let networkDeniedInterpreter = CoreAgentAppleRemoteCodeInterpreter(
      actionGate: localOnlyGate,
      policy: CoreAgentAppleRemoteCodeInterpreterPolicy(allowedEndpointURLs: [endpoint]),
      clock: { now }
    )
    let networkDenied = await networkDeniedInterpreter.run(
      CoreAgentAppleRemoteCodeInterpreterRequest(
        id: "remote-2",
        endpointURL: endpoint
      ),
      consent: .granted(receipt)
    )

    #expect(denied.status == .failed(.invalidRequest("remote backend unavailable")))
    #expect(
      networkDenied.status
        == .failed(.invalidRequest("remote execution requires allowed network policy"))
    )
  }

}

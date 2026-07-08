# VibeProxy Review Prompt: CoreAgentEngine and CoreAgentSkills Foundation

Review the Swift code below for correctness, concurrency, data-integrity, security, brittle tests, and contract gaps. Return PASS or BLOCK. If BLOCK, list findings with file/symbol, severity, why it matters, and a concrete fix. Focus on P0/P1/P2 blockers. Do not ask for broad future work unless it invalidates this slice.

Important intended contracts:
- CoreAgentEngine stores finalized CoreAgentRun evidence, verifies receipts after readback, redacts secret-marked fields, and groups failed runs by typed event evidence rather than arbitrary message prose.
- CoreAgentSkills follows SkillOpt-style text-space optimization: typed bounded edits, held-out validation gates, rejected-edit memory, best_skill.md export, and held-out harness selection.
- This slice does not claim cloud LangSmith export, model-generated diagnosis, autonomous PR creation, file-backed stores, or Apple platform adapters.


## Package.swift

```swift
// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "CoreAgent",
  platforms: [
    .iOS(.v27),
    .macOS(.v27),
    .visionOS(.v27),
  ],
  products: [
    .library(name: "CoreAgent", targets: ["CoreAgent"]),
    .library(name: "CoreAgentDeep", targets: ["CoreAgentDeep"]),
    .library(name: "CoreAgentEngine", targets: ["CoreAgentEngine"]),
    .library(name: "CoreAgentGraph", targets: ["CoreAgentGraph"]),
    .library(name: "CoreAgentMemory", targets: ["CoreAgentMemory"]),
    .library(name: "CoreAgentSkills", targets: ["CoreAgentSkills"]),
    .library(name: "CoreAgentTestSupport", targets: ["CoreAgentTestSupport"]),
    .library(name: "CoreAgentProviders", targets: ["CoreAgentProviders"]),
  ],
  traits: [
    .trait(
      name: "AppleUtilities",
      description:
        "Enable Apple's FoundationModelsUtilities provider, including its generic Chat Completions client."
    ),
    .trait(
      name: "Claude",
      description: "Enable Anthropic's ClaudeForFoundationModels provider."
    ),
    .trait(
      name: "Gemini",
      description: "Enable Firebase AI Logic's Gemini Foundation Models provider."
    ),
    .trait(
      name: "AllProviders",
      description: "Enable every first-party provider integration.",
      enabledTraits: ["AppleUtilities", "Claude", "Gemini"]
    ),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/foundation-models-utilities.git",
      revision: "a047a503b8ec79a76aa0e83d5a3bac54493cc7e5"
    ),
    .package(
      url: "https://github.com/anthropics/ClaudeForFoundationModels.git",
      exact: "0.1.2"
    ),
    .package(
      url: "https://github.com/firebase/firebase-ios-sdk.git",
      revision: "eb640a7bd9f8f4e4843e61c12a24c0abe4044443"
    ),
  ],
  targets: [
    .target(name: "CoreAgent"),
    .target(
      name: "CoreAgentDeep",
      dependencies: ["CoreAgent", "CoreAgentGraph"]
    ),
    .target(
      name: "CoreAgentEngine",
      dependencies: ["CoreAgent"]
    ),
    .target(
      name: "CoreAgentGraph",
      dependencies: ["CoreAgent"]
    ),
    .target(
      name: "CoreAgentMemory",
      dependencies: ["CoreAgent"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    .target(
      name: "CoreAgentSkills",
      dependencies: ["CoreAgent"]
    ),
    .target(
      name: "CoreAgentTestSupport",
      dependencies: ["CoreAgent"]
    ),
    .target(
      name: "CoreAgentProviders",
      dependencies: [
        "CoreAgent",
        .product(
          name: "FoundationModelsUtilities",
          package: "foundation-models-utilities",
          condition: .when(traits: ["AppleUtilities"])
        ),
        .product(
          name: "ClaudeForFoundationModels",
          package: "ClaudeForFoundationModels",
          condition: .when(traits: ["Claude"])
        ),
        .product(
          name: "FirebaseAILogic",
          package: "firebase-ios-sdk",
          condition: .when(traits: ["Gemini"])
        ),
      ],
      swiftSettings: [
        .define("COREAGENT_APPLE_UTILITIES", .when(traits: ["AppleUtilities"])),
        .define("COREAGENT_CLAUDE", .when(traits: ["Claude"])),
        .define("COREAGENT_GEMINI", .when(traits: ["Gemini"])),
      ]
    ),
    .testTarget(
      name: "CoreAgentTests",
      dependencies: ["CoreAgent", "CoreAgentTestSupport"]
    ),
    .testTarget(
      name: "CoreAgentProviderTests",
      dependencies: ["CoreAgent", "CoreAgentProviders"],
      swiftSettings: [
        .define("COREAGENT_APPLE_UTILITIES", .when(traits: ["AppleUtilities"])),
        .define("COREAGENT_CLAUDE", .when(traits: ["Claude"])),
        .define("COREAGENT_GEMINI", .when(traits: ["Gemini"])),
      ]
    ),
    .testTarget(
      name: "CoreAgentMemoryTests",
      dependencies: ["CoreAgent", "CoreAgentMemory"]
    ),
    .testTarget(
      name: "CoreAgentMemoryIntegrationTests",
      dependencies: ["CoreAgent", "CoreAgentMemory", "CoreAgentTestSupport"]
    ),
    .testTarget(
      name: "CoreAgentGraphTests",
      dependencies: ["CoreAgentGraph"]
    ),
    .testTarget(
      name: "CoreAgentDeepTests",
      dependencies: ["CoreAgentDeep", "CoreAgentTestSupport"]
    ),
    .testTarget(
      name: "CoreAgentEngineTests",
      dependencies: ["CoreAgentEngine", "CoreAgentTestSupport"]
    ),
    .testTarget(
      name: "CoreAgentSkillsTests",
      dependencies: ["CoreAgentSkills"]
    ),
  ]
)

```

## Sources/CoreAgent/CoreAgentPlugin.swift

```swift
import Foundation
import FoundationModels

public enum CoreAgentSessionMode: String, Codable, Equatable, Sendable {
  case explicitModel
  case dynamicProfile
}

public enum CoreAgentPluginFailurePolicy: Sendable {
  /// Record the failure and continue without the plugin contribution.
  case recordAndContinue
  /// Fail the run when the plugin operation cannot complete.
  case failRun
}

public struct CoreAgentPluginFailurePolicies: Sendable {
  public var preparation: CoreAgentPluginFailurePolicy
  public var completion: CoreAgentPluginFailurePolicy
  public var sanitization: CoreAgentPluginFailurePolicy

  public init(
    preparation: CoreAgentPluginFailurePolicy = .recordAndContinue,
    completion: CoreAgentPluginFailurePolicy = .recordAndContinue,
    sanitization: CoreAgentPluginFailurePolicy = .failRun
  ) {
    self.preparation = preparation
    self.completion = completion
    self.sanitization = sanitization
  }

  public static let `default` = CoreAgentPluginFailurePolicies()
}

/// One deterministic text block contributed before the original user prompt.
public struct CoreAgentContextBlock: Equatable, Sendable, Identifiable {
  public let id: String
  public let content: String
  public let attributes: [String: String]

  public init(
    id: String,
    content: String,
    attributes: [String: String] = [:]
  ) {
    self.id = id
    self.content = content
    self.attributes = attributes
  }
}

public struct CoreAgentPluginEvent: Equatable, Sendable {
  public let name: String
  public let message: String
  public let attributes: [String: String]

  public init(
    name: String,
    message: String,
    attributes: [String: String] = [:]
  ) {
    self.name = name
    self.message = message
    self.attributes = attributes
  }
}

public struct CoreAgentPluginRequest: Sendable {
  public let runID: UUID
  public let prompt: Prompt
  public let contextQuery: String?
  public let metadata: CoreAgentRequestMetadata
  public let mode: CoreAgentSessionMode

  public init(
    runID: UUID,
    prompt: Prompt,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    mode: CoreAgentSessionMode
  ) {
    self.runID = runID
    self.prompt = prompt
    self.contextQuery = contextQuery
    self.metadata = metadata
    self.mode = mode
  }
}

public struct CoreAgentPluginPreparation: Sendable {
  public let contextBlocks: [CoreAgentContextBlock]
  public let events: [CoreAgentPluginEvent]

  public init(
    contextBlocks: [CoreAgentContextBlock] = [],
    events: [CoreAgentPluginEvent] = []
  ) {
    self.contextBlocks = contextBlocks
    self.events = events
  }

  public static let empty = CoreAgentPluginPreparation()
}

public struct CoreAgentPluginCompletion: Sendable {
  public let runID: UUID
  public let contextQuery: String?
  public let metadata: CoreAgentRequestMetadata
  public let rawContent: GeneratedContent
  public let transcriptEntries: [Transcript.Entry]
  public let usage: CoreAgentUsage
  public let mode: CoreAgentSessionMode

  public init(
    runID: UUID,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    rawContent: GeneratedContent,
    transcriptEntries: [Transcript.Entry],
    usage: CoreAgentUsage,
    mode: CoreAgentSessionMode
  ) {
    self.runID = runID
    self.contextQuery = contextQuery
    self.metadata = metadata
    self.rawContent = rawContent
    self.transcriptEntries = transcriptEntries
    self.usage = usage
    self.mode = mode
  }
}

public struct CoreAgentPluginFailure: Sendable {
  public let runID: UUID
  public let contextQuery: String?
  public let metadata: CoreAgentRequestMetadata
  public let errorDescription: String
  public let errorType: String
  public let mode: CoreAgentSessionMode

  public init(
    runID: UUID,
    contextQuery: String?,
    metadata: CoreAgentRequestMetadata,
    error: any Error,
    mode: CoreAgentSessionMode
  ) {
    self.runID = runID
    self.contextQuery = contextQuery
    self.metadata = metadata
    self.errorDescription = String(describing: error)
    self.errorType = String(reflecting: Swift.type(of: error))
    self.mode = mode
  }
}

/// Extends a native CoreAgent run without introducing another model abstraction.
public protocol CoreAgentSessionPlugin: Sendable {
  var identifier: String { get }
  var tools: [any Tool] { get }
  var failurePolicies: CoreAgentPluginFailurePolicies { get }

  func prepare(for request: CoreAgentPluginRequest) async throws -> CoreAgentPluginPreparation
  func didComplete(_ completion: CoreAgentPluginCompletion) async throws -> [CoreAgentPluginEvent]
  func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent]
}

/// Receives the finalized CoreAgent run object after all run events are recorded.
public protocol CoreAgentRunObserver: Sendable {
  func coreAgentRunDidFinish(_ run: CoreAgentRun) async
}

extension CoreAgentSessionPlugin {
  public var tools: [any Tool] { [] }
  public var failurePolicies: CoreAgentPluginFailurePolicies { .default }

  public func prepare(for request: CoreAgentPluginRequest) async throws
    -> CoreAgentPluginPreparation
  {
    .empty
  }

  public func didComplete(_ completion: CoreAgentPluginCompletion) async throws
    -> [CoreAgentPluginEvent]
  {
    []
  }

  public func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent] {
    []
  }
}

```

## Sources/CoreAgentEngine/CoreAgentEngine.swift

```swift
import CoreAgent
import CryptoKit
import Foundation

public struct CoreAgentEngineTrace: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID { run.id }

  public let projectID: String
  public let threadID: String?
  public let run: CoreAgentRun
  public let receipt: CoreAgentRunReceipt
  public let ingestedAt: Date

  public init(
    projectID: String,
    threadID: String?,
    run: CoreAgentRun,
    receipt: CoreAgentRunReceipt,
    ingestedAt: Date = Date()
  ) {
    self.projectID = projectID
    self.threadID = threadID
    self.run = run
    self.receipt = receipt
    self.ingestedAt = ingestedAt
  }
}

public enum CoreAgentEngineIssueStatus: String, Codable, Equatable, Sendable {
  case open
  case ignored
  case resolved
  case reopened
}

public struct CoreAgentEngineIssue: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let projectID: String
  public let fingerprint: String
  public let title: String
  public let contributingRunIDs: [UUID]
  public let status: CoreAgentEngineIssueStatus
  public let firstSeenAt: Date
  public let lastSeenAt: Date

  public init(
    id: String,
    projectID: String,
    fingerprint: String,
    title: String,
    contributingRunIDs: [UUID],
    status: CoreAgentEngineIssueStatus,
    firstSeenAt: Date,
    lastSeenAt: Date
  ) {
    self.id = id
    self.projectID = projectID
    self.fingerprint = fingerprint
    self.title = title
    self.contributingRunIDs = contributingRunIDs
    self.status = status
    self.firstSeenAt = firstSeenAt
    self.lastSeenAt = lastSeenAt
  }
}

public protocol CoreAgentEngineStore: Sendable {
  @discardableResult
  func ingest(
    _ run: CoreAgentRun,
    projectID: String,
    threadID: String?
  ) async throws -> CoreAgentEngineTrace

  func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace?
  func traces(projectID: String, threadID: String?) async -> [CoreAgentEngineTrace]
  func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue
  func updateIssueStatus(_ issueID: String, status: CoreAgentEngineIssueStatus) async throws
  func issues(
    projectID: String,
    status: CoreAgentEngineIssueStatus?
  ) async -> [CoreAgentEngineIssue]
}

public extension CoreAgentEngineStore {
  @discardableResult
  func ingest(
    _ run: CoreAgentRun,
    projectID: String,
    threadID: String? = nil
  ) async throws -> CoreAgentEngineTrace {
    try await ingest(run, projectID: projectID, threadID: threadID)
  }

  func traces(projectID: String) async -> [CoreAgentEngineTrace] {
    await traces(projectID: projectID, threadID: nil)
  }

  func issues(projectID: String) async -> [CoreAgentEngineIssue] {
    await issues(projectID: projectID, status: nil)
  }
}

public struct CoreAgentEngineRedactionPolicy: Sendable {
  private let redactor: @Sendable (String) -> String

  public init(_ redactor: @escaping @Sendable (String) -> String) {
    self.redactor = redactor
  }

  public func redact(_ value: String) -> String {
    redactor(value)
  }

  public static let standard = CoreAgentEngineRedactionPolicy { value in
    var result = value
    let patterns: [(String, String)] = [
      (#"(?i)bearer\s+[a-z0-9._~+/=-]+"#, "Bearer [REDACTED]"),
      (#"(?i)\bsk-[a-z0-9_-]{8,}\b"#, "[REDACTED_API_KEY]"),
      (
        #"(?i)\b(api[_-]?key|token|secret|password)\s*[:=]\s*[^\s,;]+"#,
        "$1=[REDACTED]"
      ),
    ]
    for (pattern, replacement) in patterns {
      result = result.replacingOccurrences(
        of: pattern,
        with: replacement,
        options: .regularExpression
      )
    }
    return result
  }

  func redact(attributes: [String: String]) -> [String: String] {
    let sensitiveMarkers = ["authorization", "api_key", "apikey", "token", "secret", "password"]
    return attributes.reduce(into: [:]) { result, pair in
      if sensitiveMarkers.contains(where: { pair.key.lowercased().contains($0) }) {
        result[pair.key] = "[REDACTED]"
      } else {
        result[pair.key] = redactor(pair.value)
      }
    }
  }

  func redact(run: CoreAgentRun) -> CoreAgentRun {
    CoreAgentRun(
      id: run.id,
      startedAt: run.startedAt,
      endedAt: run.endedAt,
      usage: run.usage,
      events: run.events.map { event in
        CoreAgentEvent(
          id: event.id,
          runID: event.runID,
          timestamp: event.timestamp,
          kind: event.kind,
          message: redact(event.message),
          attributes: redact(attributes: event.attributes)
        )
      }
    )
  }
}

public actor InMemoryCoreAgentEngineStore: CoreAgentEngineStore {
  private let redactionPolicy: CoreAgentEngineRedactionPolicy
  private var tracesByKey: [TraceKey: StoredTrace] = [:]
  private var issuesByID: [String: CoreAgentEngineIssue] = [:]
  private var nextSequence = 0

  public init(redactionPolicy: CoreAgentEngineRedactionPolicy = .standard) {
    self.redactionPolicy = redactionPolicy
  }

  @discardableResult
  public func ingest(
    _ run: CoreAgentRun,
    projectID: String,
    threadID: String? = nil
  ) async throws -> CoreAgentEngineTrace {
    let redactedRun = redactionPolicy.redact(run: run)
    let trace = try CoreAgentEngineTrace(
      projectID: projectID,
      threadID: threadID,
      run: redactedRun,
      receipt: CoreAgentRunReceipt(run: redactedRun)
    )
    let sequence = nextSequence
    nextSequence += 1
    tracesByKey[TraceKey(projectID: projectID, runID: redactedRun.id)] = StoredTrace(
      sequence: sequence,
      trace: trace
    )
    return trace
  }

  public func trace(projectID: String, runID: UUID) async -> CoreAgentEngineTrace? {
    tracesByKey[TraceKey(projectID: projectID, runID: runID)]?.trace
  }

  public func traces(projectID: String, threadID: String? = nil) async -> [CoreAgentEngineTrace] {
    tracesByKey.values
      .filter {
        $0.trace.projectID == projectID
          && (threadID == nil || $0.trace.threadID == threadID)
      }
      .sorted { $0.sequence < $1.sequence }
      .map(\.trace)
  }

  public func upsertIssue(_ issue: CoreAgentEngineIssue) async throws -> CoreAgentEngineIssue {
    if let existing = issuesByID[issue.id] {
      let merged = CoreAgentEngineIssue(
        id: existing.id,
        projectID: existing.projectID,
        fingerprint: existing.fingerprint,
        title: issue.title,
        contributingRunIDs: issue.contributingRunIDs,
        status: existing.status,
        firstSeenAt: min(existing.firstSeenAt, issue.firstSeenAt),
        lastSeenAt: max(existing.lastSeenAt, issue.lastSeenAt)
      )
      issuesByID[issue.id] = merged
      return merged
    }
    issuesByID[issue.id] = issue
    return issue
  }

  public func updateIssueStatus(
    _ issueID: String,
    status: CoreAgentEngineIssueStatus
  ) async throws {
    guard let issue = issuesByID[issueID] else { return }
    issuesByID[issueID] = CoreAgentEngineIssue(
      id: issue.id,
      projectID: issue.projectID,
      fingerprint: issue.fingerprint,
      title: issue.title,
      contributingRunIDs: issue.contributingRunIDs,
      status: status,
      firstSeenAt: issue.firstSeenAt,
      lastSeenAt: issue.lastSeenAt
    )
  }

  public func issues(
    projectID: String,
    status: CoreAgentEngineIssueStatus? = nil
  ) async -> [CoreAgentEngineIssue] {
    issuesByID.values
      .filter { $0.projectID == projectID && (status == nil || $0.status == status) }
      .sorted { lhs, rhs in
        if lhs.firstSeenAt != rhs.firstSeenAt {
          return lhs.firstSeenAt < rhs.firstSeenAt
        }
        return lhs.fingerprint < rhs.fingerprint
      }
  }

  private struct TraceKey: Hashable {
    let projectID: String
    let runID: UUID
  }

  private struct StoredTrace {
    let sequence: Int
    let trace: CoreAgentEngineTrace
  }
}

public struct CoreAgentEngineIssueScanner: Sendable {
  private let store: any CoreAgentEngineStore

  public init(store: any CoreAgentEngineStore) {
    self.store = store
  }

  public func scan(projectID: String) async throws -> [CoreAgentEngineIssue] {
    let traces = await store.traces(projectID: projectID)
    let groups = Dictionary(grouping: traces.compactMap(FailureEvidence.init(trace:))) {
      $0.fingerprint
    }

    var issues: [CoreAgentEngineIssue] = []
    for fingerprint in groups.keys.sorted() {
      guard let evidence = groups[fingerprint]?.sorted(by: { lhs, rhs in
        lhs.trace.run.startedAt < rhs.trace.run.startedAt
      }) else {
        continue
      }
      let first = evidence[0]
      let issue = CoreAgentEngineIssue(
        id: Self.issueID(projectID: projectID, fingerprint: fingerprint),
        projectID: projectID,
        fingerprint: fingerprint,
        title: first.title,
        contributingRunIDs: evidence.map(\.trace.run.id),
        status: .open,
        firstSeenAt: evidence.map(\.trace.run.startedAt).min() ?? Date(),
        lastSeenAt: evidence.map(\.trace.run.endedAt).max() ?? Date()
      )
      issues.append(try await store.upsertIssue(issue))
    }
    return issues
  }

  private static func issueID(projectID: String, fingerprint: String) -> String {
    let data = Data("coreagent-engine-issue-v1\u{0}\(projectID)\u{0}\(fingerprint)".utf8)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return "issue-\(digest)"
  }

  private struct FailureEvidence {
    let trace: CoreAgentEngineTrace
    let fingerprint: String
    let title: String

    init?(trace: CoreAgentEngineTrace) {
      guard let failed = trace.run.events.first(where: { $0.kind == .runFailed }) else {
        return nil
      }
      let errorType = failed.attributes["error_type"] ?? "unknown"
      let tool = failed.attributes["tool"] ?? failed.attributes["tool_name"] ?? "none"
      self.trace = trace
      self.fingerprint = [
        failed.kind.rawValue,
        errorType,
        tool,
      ].joined(separator: "|")
      self.title = "\(failed.kind.rawValue): \(errorType) / \(tool)"
    }
  }
}

public struct CoreAgentEnginePlugin: CoreAgentSessionPlugin, CoreAgentRunObserver {
  public let identifier: String
  private let store: any CoreAgentEngineStore
  private let projectID: String
  private let threadID: String?

  public init(
    identifier: String = "coreagent.engine",
    store: any CoreAgentEngineStore,
    projectID: String,
    threadID: String? = nil
  ) {
    self.identifier = identifier
    self.store = store
    self.projectID = projectID
    self.threadID = threadID
  }

  public func coreAgentRunDidFinish(_ run: CoreAgentRun) async {
    _ = try? await store.ingest(run, projectID: projectID, threadID: threadID)
  }
}

```

## Tests/CoreAgentEngineTests/CoreAgentEngineTests.swift

```swift
import CoreAgent
import CoreAgentEngine
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentEngine trace ingestion")
struct CoreAgentEngineTests {
  @Test("Ingests real CoreAgent runs and verifies receipts after readback")
  func ingestsRealRunsAndVerifiesReceiptsAfterReadback() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let run = Self.run(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
      events: [
        Self.event(
          runID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
          kind: .runStarted,
          message: "Run started."
        ),
        Self.event(
          runID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
          kind: .runCompleted,
          message: "Run completed."
        ),
      ]
    )

    let trace = try await store.ingest(run, projectID: "coreagent", threadID: "thread-a")
    let readback = try #require(await store.trace(projectID: "coreagent", runID: run.id))

    #expect(trace.run == run)
    #expect(readback.run == run)
    #expect(readback.receipt.verify())
    #expect(readback.receipt.runID == run.id)
    #expect(readback.projectID == "coreagent")
    #expect(readback.threadID == "thread-a")
  }

  @Test("Queries traces by project and optional thread")
  func queriesTracesByProjectAndThread() async throws {
    let store = InMemoryCoreAgentEngineStore()
    try await store.ingest(Self.run(id: Self.uuid(201)), projectID: "coreagent", threadID: "a")
    try await store.ingest(Self.run(id: Self.uuid(202)), projectID: "coreagent", threadID: "b")
    try await store.ingest(Self.run(id: Self.uuid(203)), projectID: "other", threadID: "a")

    #expect(await store.traces(projectID: "coreagent").map(\.run.id) == [
      Self.uuid(201),
      Self.uuid(202),
    ])
    #expect(await store.traces(projectID: "coreagent", threadID: "a").map(\.run.id) == [
      Self.uuid(201)
    ])
  }

  @Test("Redacts secret-marked fields before trace storage")
  func redactsSecretMarkedFieldsBeforeTraceStorage() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let runID = Self.uuid(301)
    let run = Self.run(
      id: runID,
      events: [
        Self.event(
          runID: runID,
          kind: .toolExecutionFailed,
          message: "Failed with token=canary-not-a-token-regex",
          attributes: [
            "api_key": "canary-not-a-token-regex",
            "tool": "search",
          ]
        )
      ]
    )

    let trace = try await store.ingest(run, projectID: "coreagent")
    let event = try #require(trace.run.events.first)

    #expect(event.message == "Failed with token=[REDACTED]")
    #expect(event.attributes["api_key"] == "[REDACTED]")
    #expect(event.attributes["tool"] == "search")
    #expect(trace.receipt.verify())
  }

  @Test("Failed run scan clusters issues by typed failure evidence")
  func failedRunScanClustersIssuesByTypedFailureEvidence() async throws {
    let store = InMemoryCoreAgentEngineStore()
    try await store.ingest(
      Self.failedRun(id: Self.uuid(401), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    try await store.ingest(
      Self.failedRun(id: Self.uuid(402), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    try await store.ingest(
      Self.failedRun(id: Self.uuid(403), errorType: "timeout", tool: "browser"),
      projectID: "coreagent"
    )

    let scanner = CoreAgentEngineIssueScanner(store: store)
    let issues = try await scanner.scan(projectID: "coreagent")

    #expect(issues.map(\.contributingRunIDs) == [
      [Self.uuid(401), Self.uuid(402)],
      [Self.uuid(403)],
    ])
    #expect(issues.map(\.status) == [.open, .open])
    #expect(issues.map(\.fingerprint) == [
      "runFailed|authorization|write_file",
      "runFailed|timeout|browser",
    ])
  }

  @Test("Issues can be filtered by project and lifecycle status")
  func issuesCanBeFilteredByProjectAndLifecycleStatus() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let scanner = CoreAgentEngineIssueScanner(store: store)
    try await store.ingest(
      Self.failedRun(id: Self.uuid(501), errorType: "authorization", tool: "write_file"),
      projectID: "coreagent"
    )
    try await store.ingest(
      Self.failedRun(id: Self.uuid(502), errorType: "authorization", tool: "write_file"),
      projectID: "other"
    )

    let issues = try await scanner.scan(projectID: "coreagent")
    let issue = try #require(issues.first)
    try await store.updateIssueStatus(issue.id, status: .resolved)

    #expect(await store.issues(projectID: "coreagent", status: .resolved).map(\.id) == [
      issue.id
    ])
    #expect(await store.issues(projectID: "coreagent", status: .open).isEmpty)
    #expect(await store.issues(projectID: "other", status: .open).isEmpty)
  }

  @Test("Engine plugin ingests the finalized CoreAgent run")
  func enginePluginIngestsFinalizedCoreAgentRun() async throws {
    let store = InMemoryCoreAgentEngineStore()
    let plugin = CoreAgentEnginePlugin(
      store: store,
      projectID: "coreagent",
      threadID: "session-thread"
    )
    let session = try CoreAgentSession(
      model: RecordedLanguageModel(steps: [
        .response(text: "ok", inputTokens: 11, cachedInputTokens: 3, outputTokens: 5)
      ]),
      plugins: [plugin]
    )

    let response = try await session.respond(to: "hello")
    let trace = try #require(await store.trace(projectID: "coreagent", runID: response.run.id))

    #expect(trace.run == response.run)
    #expect(trace.threadID == "session-thread")
    #expect(trace.receipt.verify())
    #expect(trace.run.events.contains { $0.kind == .runCompleted })
    #expect(trace.run.usage == response.usage)
  }

  private static func failedRun(id: UUID, errorType: String, tool: String) -> CoreAgentRun {
    run(
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

  private static func run(
    id: UUID,
    events: [CoreAgentEvent] = []
  ) -> CoreAgentRun {
    CoreAgentRun(
      id: id,
      startedAt: Date(timeIntervalSince1970: 1),
      endedAt: Date(timeIntervalSince1970: 2),
      usage: CoreAgentUsage(
        inputTokens: 10,
        cachedInputTokens: 2,
        outputTokens: 4,
        reasoningTokens: 1
      ),
      events: events
    )
  }

  private static func event(
    runID: UUID,
    kind: CoreAgentEventKind,
    message: String,
    attributes: [String: String] = [:]
  ) -> CoreAgentEvent {
    CoreAgentEvent(
      id: UUID(),
      runID: runID,
      timestamp: Date(timeIntervalSince1970: 1),
      kind: kind,
      message: message,
      attributes: attributes
    )
  }

  private static func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", suffix))")!
  }
}

```

## Sources/CoreAgentSkills/CoreAgentSkills.swift

```swift
import CoreAgent
import Foundation

public struct CoreAgentSkillID:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral
{
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(stringLiteral value: String) {
    self.rawValue = value
  }
}

public struct CoreAgentSkill: Codable, Equatable, Sendable, Identifiable {
  public let id: CoreAgentSkillID
  public let version: Int
  public let title: String
  public let body: String
  public let tags: [String]
  public let priority: Int
  public let provenance: [CoreAgentSkillProvenance]

  public init(
    id: CoreAgentSkillID,
    version: Int,
    title: String,
    body: String,
    tags: [String] = [],
    priority: Int = 0,
    provenance: [CoreAgentSkillProvenance] = []
  ) {
    self.id = id
    self.version = version
    self.title = title
    self.body = body
    self.tags = tags
    self.priority = priority
    self.provenance = provenance
  }
}

public struct CoreAgentSkillProvenance: Codable, Equatable, Sendable {
  public let acceptedAt: Date
  public let heldoutSuiteID: String
  public let validationScore: Double
  public let notes: String

  public init(
    acceptedAt: Date = Date(),
    heldoutSuiteID: String,
    validationScore: Double,
    notes: String
  ) {
    self.acceptedAt = acceptedAt
    self.heldoutSuiteID = heldoutSuiteID
    self.validationScore = validationScore
    self.notes = notes
  }
}

public struct CoreAgentSkillValidationResult: Codable, Equatable, Sendable {
  public let score: Double
  public let heldoutSuiteID: String
  public let passed: Bool
  public let notes: String

  public init(score: Double, heldoutSuiteID: String, passed: Bool, notes: String) {
    self.score = score
    self.heldoutSuiteID = heldoutSuiteID
    self.passed = passed
    self.notes = notes
  }
}

public enum CoreAgentSkillEdit: Codable, Equatable, Sendable {
  case replace(target: String, replacement: String)
  case append(String)

  func apply(to body: String) throws -> String {
    switch self {
    case .append(let addition):
      return body + addition
    case .replace(let target, let replacement):
      guard !target.isEmpty else {
        throw CoreAgentSkillOptimizationError.emptyReplacementTarget
      }
      let parts = body.components(separatedBy: target)
      guard parts.count == 2 else {
        throw CoreAgentSkillOptimizationError.replacementTargetNotUnique(target)
      }
      return parts[0] + replacement + parts[1]
    }
  }
}

public enum CoreAgentSkillOptimizationError: Error, Equatable, Sendable {
  case missingSkill(CoreAgentSkillID)
  case emptyReplacementTarget
  case replacementTargetNotUnique(String)
  case missingHarnessEvaluation(String)
}

public struct CoreAgentSkillOptimizationProposal: Sendable {
  public let skillID: CoreAgentSkillID
  public let baselineScore: Double
  public let candidateEdits: [CoreAgentSkillEdit]
  public let validation: CoreAgentSkillValidationResult

  public init(
    skillID: CoreAgentSkillID,
    baselineScore: Double,
    candidateEdits: [CoreAgentSkillEdit],
    validation: CoreAgentSkillValidationResult
  ) {
    self.skillID = skillID
    self.baselineScore = baselineScore
    self.candidateEdits = candidateEdits
    self.validation = validation
  }
}

public struct CoreAgentSkillOptimizationResult: Equatable, Sendable {
  public let accepted: Bool
  public let skill: CoreAgentSkill
  public let validation: CoreAgentSkillValidationResult
}

public struct CoreAgentRejectedSkillEdit: Codable, Equatable, Sendable {
  public let proposedAt: Date
  public let edits: [CoreAgentSkillEdit]
  public let validation: CoreAgentSkillValidationResult

  public init(
    proposedAt: Date = Date(),
    edits: [CoreAgentSkillEdit],
    validation: CoreAgentSkillValidationResult
  ) {
    self.proposedAt = proposedAt
    self.edits = edits
    self.validation = validation
  }
}

public struct CoreAgentSkillOptimizerMemory: Codable, Equatable, Sendable {
  public var rejectedEdits: [CoreAgentRejectedSkillEdit]

  public init(rejectedEdits: [CoreAgentRejectedSkillEdit] = []) {
    self.rejectedEdits = rejectedEdits
  }
}

public actor InMemoryCoreAgentSkillStore {
  private var historyByID: [CoreAgentSkillID: [CoreAgentSkill]] = [:]
  private var memoryByID: [CoreAgentSkillID: CoreAgentSkillOptimizerMemory] = [:]

  public init() {}

  public func save(_ skill: CoreAgentSkill) async throws {
    historyByID[skill.id, default: []].append(skill)
    historyByID[skill.id]?.sort { $0.version < $1.version }
  }

  public func currentSkill(id: CoreAgentSkillID) async -> CoreAgentSkill? {
    historyByID[id]?.max { $0.version < $1.version }
  }

  public func allCurrentSkills() async -> [CoreAgentSkill] {
    historyByID.values
      .compactMap { $0.max { $0.version < $1.version } }
      .sorted { lhs, rhs in
        if lhs.priority != rhs.priority {
          return lhs.priority > rhs.priority
        }
        return lhs.id.rawValue < rhs.id.rawValue
      }
  }

  public func optimizerMemory(skillID: CoreAgentSkillID) async -> CoreAgentSkillOptimizerMemory {
    memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
  }

  func recordRejected(_ rejected: CoreAgentRejectedSkillEdit, skillID: CoreAgentSkillID) {
    var memory = memoryByID[skillID] ?? CoreAgentSkillOptimizerMemory()
    memory.rejectedEdits.append(rejected)
    memoryByID[skillID] = memory
  }
}

public struct CoreAgentSkillCurationQuery: Sendable {
  public let tags: Set<String>
  public let maxCharacters: Int

  public init(tags: Set<String>, maxCharacters: Int) {
    self.tags = tags
    self.maxCharacters = maxCharacters
  }

  public init(tags: [String], maxCharacters: Int) {
    self.init(tags: Set(tags), maxCharacters: maxCharacters)
  }
}

public struct CoreAgentSkillCurator: Sendable {
  private let store: InMemoryCoreAgentSkillStore

  public init(store: InMemoryCoreAgentSkillStore) {
    self.store = store
  }

  public func curate(query: CoreAgentSkillCurationQuery) async -> [CoreAgentSkill] {
    var remaining = max(0, query.maxCharacters)
    var selected: [CoreAgentSkill] = []
    for skill in await store.allCurrentSkills() {
      guard !Set(skill.tags).isDisjoint(with: query.tags) else { continue }
      guard skill.body.count <= remaining else { continue }
      selected.append(skill)
      remaining -= skill.body.count
    }
    return selected
  }
}

public struct CoreAgentSkillOptimizer: Sendable {
  private let store: InMemoryCoreAgentSkillStore

  public init(store: InMemoryCoreAgentSkillStore) {
    self.store = store
  }

  public func propose(
    _ proposal: CoreAgentSkillOptimizationProposal
  ) async throws -> CoreAgentSkillOptimizationResult {
    guard let current = await store.currentSkill(id: proposal.skillID) else {
      throw CoreAgentSkillOptimizationError.missingSkill(proposal.skillID)
    }
    var candidateBody = current.body
    for edit in proposal.candidateEdits {
      candidateBody = try edit.apply(to: candidateBody)
    }

    guard proposal.validation.passed,
      proposal.validation.score > proposal.baselineScore
    else {
      await store.recordRejected(
        CoreAgentRejectedSkillEdit(
          edits: proposal.candidateEdits,
          validation: proposal.validation
        ),
        skillID: proposal.skillID
      )
      return CoreAgentSkillOptimizationResult(
        accepted: false,
        skill: current,
        validation: proposal.validation
      )
    }

    let next = CoreAgentSkill(
      id: current.id,
      version: current.version + 1,
      title: current.title,
      body: candidateBody,
      tags: current.tags,
      priority: current.priority,
      provenance: current.provenance + [
        CoreAgentSkillProvenance(
          heldoutSuiteID: proposal.validation.heldoutSuiteID,
          validationScore: proposal.validation.score,
          notes: proposal.validation.notes
        )
      ]
    )
    try await store.save(next)
    return CoreAgentSkillOptimizationResult(
      accepted: true,
      skill: next,
      validation: proposal.validation
    )
  }
}

public enum CoreAgentSkillExporter {
  public static func bestSkillMarkdown(_ skill: CoreAgentSkill) -> String {
    var lines: [String] = [
      "# \(skill.title)",
      "",
      "Version: \(skill.version)",
      "Tags: \(skill.tags.joined(separator: ", "))",
      "",
      skill.body,
    ]
    if let latest = skill.provenance.last {
      lines.append("")
      lines.append("Heldout Suite: \(latest.heldoutSuiteID)")
      lines.append("Validation Score: \(latest.validationScore)")
    }
    return lines.joined(separator: "\n")
  }
}

public struct CoreAgentHarnessCandidate: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let parameters: [String: String]

  public init(id: String, parameters: [String: String]) {
    self.id = id
    self.parameters = parameters
  }
}

public struct CoreAgentHarnessEvaluation: Codable, Equatable, Sendable {
  public let candidateID: String
  public let heldoutSuiteID: String
  public let score: Double

  public init(candidateID: String, heldoutSuiteID: String, score: Double) {
    self.candidateID = candidateID
    self.heldoutSuiteID = heldoutSuiteID
    self.score = score
  }
}

public struct CoreAgentHarnessAuditEntry: Equatable, Sendable {
  public let candidateID: String
  public let meanScore: Double
  public let heldoutSuiteIDs: [String]
}

public struct CoreAgentHarnessOptimizationResult: Equatable, Sendable {
  public let best: CoreAgentHarnessCandidate
  public let heldoutSuiteIDs: [String]
  public let auditTrail: [CoreAgentHarnessAuditEntry]
}

public struct CoreAgentHarnessOptimizer: Sendable {
  public init() {}

  public func selectBest(
    candidates: [CoreAgentHarnessCandidate],
    evaluations: [CoreAgentHarnessEvaluation]
  ) throws -> CoreAgentHarnessOptimizationResult {
    let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
    var audit: [CoreAgentHarnessAuditEntry] = []
    for candidate in candidates {
      let scores = evaluations.filter { $0.candidateID == candidate.id }
      guard !scores.isEmpty else {
        throw CoreAgentSkillOptimizationError.missingHarnessEvaluation(candidate.id)
      }
      let meanScore = scores.map(\.score).reduce(0, +) / Double(scores.count)
      audit.append(
        CoreAgentHarnessAuditEntry(
          candidateID: candidate.id,
          meanScore: meanScore,
          heldoutSuiteIDs: Array(Set(scores.map(\.heldoutSuiteID))).sorted()
        )
      )
    }
    audit.sort { lhs, rhs in
      if lhs.meanScore != rhs.meanScore {
        return lhs.meanScore > rhs.meanScore
      }
      return lhs.candidateID < rhs.candidateID
    }
    guard let bestEntry = audit.first,
      let best = candidateByID[bestEntry.candidateID]
    else {
      throw CoreAgentSkillOptimizationError.missingHarnessEvaluation("all")
    }
    return CoreAgentHarnessOptimizationResult(
      best: best,
      heldoutSuiteIDs: Array(Set(evaluations.map(\.heldoutSuiteID))).sorted(),
      auditTrail: audit
    )
  }
}

```

## Tests/CoreAgentSkillsTests/CoreAgentSkillsTests.swift

```swift
import CoreAgentSkills
import Foundation
import Testing

@Suite("CoreAgentSkills SkillOpt foundation")
struct CoreAgentSkillsTests {
  @Test("Curates skills by tags priority and context budget")
  func curatesSkillsByTagsPriorityAndContextBudget() async throws {
    let store = InMemoryCoreAgentSkillStore()
    try await store.save(Self.skill(id: "planner", body: "Plan carefully.", tags: ["planning"], priority: 10))
    try await store.save(Self.skill(id: "swift", body: "Use Swift Testing.", tags: ["swift"], priority: 20))
    try await store.save(Self.skill(id: "long", body: String(repeating: "x", count: 200), tags: ["swift"], priority: 30))

    let curator = CoreAgentSkillCurator(store: store)
    let curated = await curator.curate(
      query: CoreAgentSkillCurationQuery(tags: ["swift", "planning"], maxCharacters: 60)
    )

    #expect(curated.map(\.id.rawValue) == ["swift", "planner"])
    #expect(curated.reduce(0) { $0 + $1.body.count } <= 60)
  }

  @Test("Validation-gated edits improve score before mutating current skill")
  func validationGatedEditsImproveScoreBeforeMutatingCurrentSkill() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use XCTest.")
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)

    let result = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.70,
        candidateEdits: [
          .replace(
            target: "Use XCTest.",
            replacement: "Use Swift Testing with typed assertions."
          )
        ],
        validation: CoreAgentSkillValidationResult(
          score: 0.82,
          heldoutSuiteID: "heldout-swift",
          passed: true,
          notes: "Improves the heldout suite."
        )
      )
    )

    let current = try #require(await store.currentSkill(id: base.id))
    #expect(result.accepted)
    #expect(current.version == 2)
    #expect(current.body == "Use Swift Testing with typed assertions.")
    #expect(current.provenance.last?.heldoutSuiteID == "heldout-swift")
  }

  @Test("Rejected edits are retained as optimizer memory without mutating the skill")
  func rejectedEditsAreRetainedAsOptimizerMemoryWithoutMutatingSkill() async throws {
    let store = InMemoryCoreAgentSkillStore()
    let base = Self.skill(id: "swift", body: "Use Swift Testing.")
    try await store.save(base)
    let optimizer = CoreAgentSkillOptimizer(store: store)

    let result = try await optimizer.propose(
      CoreAgentSkillOptimizationProposal(
        skillID: base.id,
        baselineScore: 0.90,
        candidateEdits: [.append("\nAlways force unwrap.")],
        validation: CoreAgentSkillValidationResult(
          score: 0.40,
          heldoutSuiteID: "heldout-safety",
          passed: false,
          notes: "Introduces unsafe code."
        )
      )
    )

    let current = try #require(await store.currentSkill(id: base.id))
    let memory = await store.optimizerMemory(skillID: base.id)
    #expect(!result.accepted)
    #expect(current.body == base.body)
    #expect(memory.rejectedEdits.count == 1)
    #expect(memory.rejectedEdits.first?.validation.heldoutSuiteID == "heldout-safety")
  }

  @Test("Exports the current best skill as best_skill markdown")
  func exportsCurrentBestSkillMarkdown() async throws {
    let skill = Self.skill(
      id: "swift",
      body: "Use Swift Testing.",
      tags: ["swift", "testing"],
      priority: 5
    )

    let markdown = CoreAgentSkillExporter.bestSkillMarkdown(skill)

    #expect(markdown.contains("# swift"))
    #expect(markdown.contains("Version: 1"))
    #expect(markdown.contains("Tags: swift, testing"))
    #expect(markdown.contains("Use Swift Testing."))
  }

  @Test("Harness optimizer selects the best heldout configuration")
  func harnessOptimizerSelectsBestHeldoutConfiguration() async throws {
    let optimizer = CoreAgentHarnessOptimizer()
    let result = try optimizer.selectBest(
      candidates: [
        CoreAgentHarnessCandidate(id: "small", parameters: ["temperature": "0.2"]),
        CoreAgentHarnessCandidate(id: "large", parameters: ["temperature": "0.0"]),
      ],
      evaluations: [
        CoreAgentHarnessEvaluation(candidateID: "small", heldoutSuiteID: "heldout-a", score: 0.74),
        CoreAgentHarnessEvaluation(candidateID: "large", heldoutSuiteID: "heldout-a", score: 0.91),
      ]
    )

    #expect(result.best.id == "large")
    #expect(result.heldoutSuiteIDs == ["heldout-a"])
    #expect(result.auditTrail.map(\.candidateID) == ["large", "small"])
  }

  private static func skill(
    id: String,
    body: String,
    tags: [String] = [],
    priority: Int = 0
  ) -> CoreAgentSkill {
    CoreAgentSkill(
      id: CoreAgentSkillID(id),
      version: 1,
      title: id,
      body: body,
      tags: tags,
      priority: priority
    )
  }
}

```

## Documentation/CoreAgentEngine-Runtime.md

```swift
# CoreAgentEngine Runtime

Date: 2026-07-06
Status: Slice 3 local trace ingestion foundation

`CoreAgentEngine` is the portable, Foundation Models-native trace foundation for
the broader LangSmith Engine-style improvement loop. This slice intentionally
implements local run evidence and issue grouping before adding datasets,
evaluators, model-generated diagnoses, or fix automation.

## Implemented

- `CoreAgentEngineTrace`
  - Stores a project ID, optional thread ID, redacted `CoreAgentRun`,
    `CoreAgentRunReceipt`, and ingestion timestamp.
  - Receipt verification is over the stored redacted run, not the pre-redaction
    input.

- `CoreAgentEngineStore`
  - Portable async store protocol for trace ingestion, trace queries, issue
    upserts, issue status changes, and issue queries.

- `InMemoryCoreAgentEngineStore`
  - Actor-backed store for deterministic tests and local embedding.
  - Queries traces by project and optional thread.
  - Queries issues by project and optional lifecycle status.

- `CoreAgentEngineRedactionPolicy`
  - Redacts common token/API-key/password patterns in event messages.
  - Redacts attribute values when the attribute key is secret-marked, including
    canary values that do not match generic token regexes.

- `CoreAgentEngineIssueScanner`
  - Scans stored traces for `runFailed` events.
  - Builds deterministic issue fingerprints from typed failure evidence:
    event kind, `error_type`, and `tool`/`tool_name`.
  - Does not cluster from arbitrary prose.
  - Preserves existing issue lifecycle status on rescan.

- `CoreAgentRunObserver`
  - A CoreAgent hook that receives the finalized `CoreAgentRun` after all run
    events have been recorded.

- `CoreAgentEnginePlugin`
  - Session plugin/run observer that ingests the finalized `CoreAgentRun`
    object into a configured Engine store.

## Explicit Non-Goals For This Slice

- No LangSmith cloud export.
- No SQLite trace store yet.
- No dataset/evaluator/proposed-fix model yet.
- No autonomous PR creation.
- No model-generated diagnosis or self-improvement loop.
- No SwiftData, SwiftUI, App Intents, sandbox, or computer-use adapters.

Those should layer on this portable trace contract instead of replacing it.

## Verification

- `swift test --skip-update --filter CoreAgentEngineTests` passed 6 Engine
  tests after implementation.
- `swift test --skip-update --filter CoreAgentTests` passed 45 CoreAgent tests
  after adding the finalized-run observer hook.
- `swift test --skip-update` passed the full package suite.
- `swift build --skip-update` completed successfully.

```

## Documentation/CoreAgentSkills-Runtime.md

```swift
# CoreAgentSkills Runtime

Date: 2026-07-06
Status: Slice 4 SkillOpt local foundation

`CoreAgentSkills` is the portable skill curation and text-space optimization
target. It follows SkillOpt's stable contract at the Swift boundary: skill
documents are trainable external state, edits are typed and bounded, held-out
validation gates acceptance, and rejected edits become optimizer memory instead
of silent prompt drift.

## Implemented

- `CoreAgentSkill`
  - Versioned skill document with ID, title, body, tags, priority, and accepted
    provenance.

- `InMemoryCoreAgentSkillStore`
  - Actor-backed skill history and current-skill lookup.
  - Stores optimizer memory separately from the current skill body.

- `CoreAgentSkillCurator`
  - Selects current skills by tag, priority, stable ID ordering, and character
    budget.
  - Skips oversized skills rather than truncating skill text into an invalid
    partial instruction.

- `CoreAgentSkillEdit`
  - Typed edit operations: unique-target replace and append.
  - Replacement fails unless the target occurs exactly once.

- `CoreAgentSkillOptimizer`
  - Applies candidate edits only when held-out validation passes and improves
    over the baseline score.
  - Accepted edits increment skill version and record held-out provenance.
  - Rejected edits are retained as optimizer memory without mutating the skill.

- `CoreAgentSkillExporter`
  - Exports the current skill as `best_skill.md`-style Markdown.

- `CoreAgentHarnessOptimizer`
  - Selects the best harness candidate from held-out evaluation results.
  - Keeps an audit trail sorted by mean held-out score.

## Explicit Non-Goals For This Slice

- No model-powered edit proposer yet.
- No nightly SkillOpt-Sleep loop yet.
- No integration with `CoreAgentEngine` issues yet.
- No recursive self-improvement scheduler yet.
- No file-backed skill store yet.

Those should build on this typed edit, validation, and optimizer-memory
contract.

## Verification

- `swift test --skip-update --filter CoreAgentSkillsTests` passed 5 Skills
  tests after implementation.
- `swift test --skip-update` passed the full package suite after adding the
  Skills target.
- `swift build --skip-update` completed successfully.

```

## Sources/CoreAgent/CoreAgentSession.swift relevant snippets

```swift
  private let retention: CoreAgentTranscriptRetention
  private let requiresMatchingCheckpointConfiguration: Bool
  private let checkpointCompatibilityRevision: String
  private let recordsProfileToolLifecycle: Bool
  private let sessionMode: CoreAgentSessionMode
  private let plugins: [any CoreAgentSessionPlugin]
  private let runLifecycleTools: [any CoreAgentRunLifecycleTool]
  private let runObservers: [any CoreAgentRunObserver]
  private let toolRuntime: CoreAgentToolRuntime
  private let recorder: CoreAgentEventRecorder

  private var nativeSession: LanguageModelSession?
  private var mostRecentRun: CoreAgentRun?
  private var hasActiveOperation = false

  public init<Model: LanguageModel>(
    model: Model,
    tools: [any Tool] = [],
    instructions: Instructions? = nil,
    configuration: CoreAgentConfiguration = .default,
    toolConfiguration: CoreAgentToolConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    requiresMatchingToolset: Bool = true,
    instructionRestorationPolicy: CoreAgentInstructionRestorationPolicy = .replaceWithCurrent,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default
  ) throws {
    try Self.validate(
      configuration: configuration,
      toolConfiguration: toolConfiguration,
      transcriptRetention: transcriptRetention,
      observerDeliveryConfiguration: observerDeliveryConfiguration
    )
    try Self.validate(plugins: plugins)

    let recorder = CoreAgentEventRecorder(
      observers: observers,
      redactionPolicy: redactionPolicy,
      deliveryConfiguration: observerDeliveryConfiguration
    )
    let runtime = CoreAgentToolRuntime(maximumCallsPerRun: toolConfiguration.maximumCallsPerRun)
    let allTools = tools + plugins.flatMap(\.tools)
    let runLifecycleTools = allTools.compactMap { $0 as? any CoreAgentRunLifecycleTool }
    let runObservers =
      plugins.compactMap { $0 as? any CoreAgentRunObserver }
      + allTools.compactMap { $0 as? any CoreAgentRunObserver }
    try Self.validateUniqueToolNames(allTools)
    let prepared = try allTools.map { tool -> (any Tool, CoreAgentToolManifest) in
      let manifest = try CoreAgentToolManifest(tool: tool)
      let erased = CoreAgentAnyTool(tool)
      let governed = CoreAgentGovernedTool(
        base: erased,
        manifest: manifest,
        configuration: toolConfiguration,
        runtime: runtime,
        recorder: recorder
      )
      return (governed, manifest)
    }
    let governedTools = prepared.map(\.0)
    let revision = Self.makeToolsetRevision(prepared.map(\.1))

    let makeSession: SessionFactory = { transcript in
      if let transcript {
        if case .replaceWithCurrent = instructionRestorationPolicy,
          instructions != nil
        {
          let current = LanguageModelSession(
            model: model,
            tools: governedTools,
            instructions: instructions
          )
          var rebased = current.transcript
          rebased.history = transcript.history
          return LanguageModelSession(model: model, tools: governedTools, transcript: rebased)
        }
        return LanguageModelSession(model: model, tools: governedTools, transcript: transcript)
      }
      return LanguageModelSession(model: model, tools: governedTools, instructions: instructions)
    }
    self.init(
      makeSession: makeSession,
      configuration: configuration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      requiresMatchingCheckpointConfiguration: requiresMatchingToolset,
      checkpointCompatibilityRevision: revision,
      recordsProfileToolLifecycle: false,
      sessionMode: .explicitModel,
      plugins: plugins,
      runLifecycleTools: runLifecycleTools,
      runObservers: runObservers,
      toolRuntime: runtime,
      recorder: recorder
    )
  }

  /// Creates a harness around a native Xcode 27 dynamic profile.
  ///
  /// The factory is called again for lazy checkpoint restoration and `reset()`.
  /// Profile-owned tools remain native and are not wrapped by CoreAgent policy.
  public init<Profile: LanguageModelSession.DynamicProfile>(
    checkpointCompatibilityID: String,
    configuration: CoreAgentConfiguration = .default,
    checkpointStore: (any CoreAgentCheckpointStore)? = nil,
    checkpointKey: String = "default",
    transcriptRetention: CoreAgentTranscriptRetention = .complete,
    plugins: [any CoreAgentSessionPlugin] = [],
    redactionPolicy: CoreAgentRedactionPolicy = .standard,
    observers: [any CoreAgentObserver] = [],
    observerDeliveryConfiguration: CoreAgentObserverDeliveryConfiguration = .default,
    profile makeProfile: @escaping @Sendable () -> sending Profile
  ) throws {
    try Self.validate(
      configuration: configuration,
      toolConfiguration: .default,
      transcriptRetention: transcriptRetention,
      observerDeliveryConfiguration: observerDeliveryConfiguration
    )
    try Self.validate(plugins: plugins)
    guard !checkpointCompatibilityID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw CoreAgentError.emptyCheckpointCompatibilityID
    }
    if configuration.retryPolicy.maximumAttempts > 1 {
      throw CoreAgentError.unsafeRetryConfiguration(
        "Dynamic profiles may preserve partial history or own tools and lifecycle hooks that CoreAgent cannot intercept. Profile mode supports one attempt."
      )
    }

    let recorder = CoreAgentEventRecorder(
      observers: observers,
      redactionPolicy: redactionPolicy,
      deliveryConfiguration: observerDeliveryConfiguration
    )
    let runtime = CoreAgentToolRuntime(maximumCallsPerRun: nil)
    let runLifecycleTools = plugins.flatMap(\.tools).compactMap {
      $0 as? any CoreAgentRunLifecycleTool
    }
    let runObservers =
      plugins.compactMap { $0 as? any CoreAgentRunObserver }
      + plugins.flatMap(\.tools).compactMap { $0 as? any CoreAgentRunObserver }
    let revision = Self.makeProfileRevision(checkpointCompatibilityID)
    let makeSession: SessionFactory = { transcript in
      let profile = makeProfile()
        .onToolCall { call in
          guard let runID = await runtime.activeRunID() else { return }
          await recorder.record(
            runID: runID,
            kind: .nativeToolCallRecorded,
            message: "Native dynamic profile emitted a tool call.",
            attributes: [
              "native_call_id": call.id,
              "tool": call.toolName,
            ]
          )
        }
        .onToolOutput { call, _ in
          guard let runID = await runtime.activeRunID() else { return }
          await recorder.record(
            runID: runID,
            kind: .nativeToolOutputRecorded,
            message: "Native dynamic profile emitted tool output.",
            attributes: [
              "native_call_id": call.id,
              "tool": call.toolName,
            ]
          )
        }
      return LanguageModelSession(
        profile: profile,
        history: transcript?.history ?? []
      )
    }
    self.init(
      makeSession: makeSession,
      configuration: configuration,
      checkpointStore: checkpointStore,
      checkpointKey: checkpointKey,
      transcriptRetention: transcriptRetention,
      requiresMatchingCheckpointConfiguration: true,
      checkpointCompatibilityRevision: revision,
      recordsProfileToolLifecycle: true,
      sessionMode: .dynamicProfile,
      plugins: plugins,
      runLifecycleTools: runLifecycleTools,
      runObservers: runObservers,
      toolRuntime: runtime,
      recorder: recorder
    )
  }

  private init(
    makeSession: @escaping SessionFactory,
    configuration: CoreAgentConfiguration,
    checkpointStore: (any CoreAgentCheckpointStore)?,
    checkpointKey: String,
    transcriptRetention: CoreAgentTranscriptRetention,
    requiresMatchingCheckpointConfiguration: Bool,
    checkpointCompatibilityRevision: String,
    recordsProfileToolLifecycle: Bool,
    sessionMode: CoreAgentSessionMode,
    plugins: [any CoreAgentSessionPlugin],
    runLifecycleTools: [any CoreAgentRunLifecycleTool],
    runObservers: [any CoreAgentRunObserver],
    toolRuntime: CoreAgentToolRuntime,
    recorder: CoreAgentEventRecorder
  ) {
    self.makeSession = makeSession
    self.configuration = configuration
    self.checkpointStore = checkpointStore
    self.checkpointKey = checkpointKey
    self.retention = transcriptRetention
    self.requiresMatchingCheckpointConfiguration = requiresMatchingCheckpointConfiguration
    self.checkpointCompatibilityRevision = checkpointCompatibilityRevision
      await recorder.record(
        runID: runID,
        kind: .modelResponseCompleted,
        message: "Native model response completed.",
        attributes: [
          "input_tokens": String(usage.inputTokens),
          "output_tokens": String(usage.outputTokens),
          "transcript_entries": String(nativeResponse.transcriptEntries.count),
        ]
      )
      let persisted = try await persistAfterSuccessfulResponse(
        transcript: sanitizedTranscript,
        runID: runID
      )
      try await completePlugins(
        CoreAgentPluginCompletion(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          rawContent: nativeResponse.rawContent,
          transcriptEntries: runTranscriptEntries,
          usage: usage,
          mode: sessionMode
        )
      )
      await recordActiveSessionCompactionIfNeeded(
        installed: installActiveSessionTranscriptIfNeeded(from: persisted),
        persisted: persisted,
        runID: runID
      )
      await finishRunLifecycleTools(runID: runID)
      await recorder.record(
        runID: runID, kind: .runCompleted, message: "Foundation Models run completed.")
      let run = await finishRun(runID: runID, startedAt: startedAt, usage: usage)
      await notifyRunObservers(run)
      await toolRuntime.finish(runID: runID)
      return CoreAgentResponse(
        content: nativeResponse.content,
        rawContent: nativeResponse.rawContent,
        transcriptEntries: Array(nativeResponse.transcriptEntries),
        usage: usage,
        run: run
      )
    } catch {
      if !pluginContext.contextBlocks.isEmpty {
        let sanitized = await sanitizeFailedTranscript(
          session.transcript,
          fallback: transcriptBeforeRun,
          context: pluginContext,
          runID: runID
        )
        installSession(transcript: sanitized, ifNeededFor: pluginContext)
        if configuration.savesTranscriptAfterFailedResponse {
          await persistAfterFailedResponse(transcript: sanitized, runID: runID)
        }
      } else if configuration.savesTranscriptAfterFailedResponse, !completedModelResponse {
        await persistAfterFailedResponse(transcript: session.transcript, runID: runID)
      }
      await failPlugins(
        CoreAgentPluginFailure(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          error: error,
          mode: sessionMode
        )
      )
      await finishRunLifecycleTools(runID: runID)
      await recorder.record(
        runID: runID,
        kind: .runFailed,
          "transcript_entries": String(lastSnapshot.transcriptEntries.count),
        ]
      )
      let persisted = try await persistAfterSuccessfulResponse(
        transcript: sanitizedTranscript,
        runID: runID
      )
      try await completePlugins(
        CoreAgentPluginCompletion(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          rawContent: lastSnapshot.rawContent,
          transcriptEntries: runTranscriptEntries,
          usage: usage,
          mode: sessionMode
        )
      )
      await recordActiveSessionCompactionIfNeeded(
        installed: installActiveSessionTranscriptIfNeeded(from: persisted),
        persisted: persisted,
        runID: runID
      )
      await finishRunLifecycleTools(runID: runID)
      await recorder.record(
        runID: runID, kind: .runCompleted, message: "Foundation Models run completed.")
      let run = await finishRun(runID: runID, startedAt: startedAt, usage: usage)
      await notifyRunObservers(run)
      await toolRuntime.finish(runID: runID)
      return CoreAgentResponse(
        content: content,
        rawContent: lastSnapshot.rawContent,
        transcriptEntries: Array(lastSnapshot.transcriptEntries),
        usage: usage,
        run: run
      )
    } catch {
      if !pluginContext.contextBlocks.isEmpty {
        let sanitized = await sanitizeFailedTranscript(
          session.transcript,
          fallback: transcriptBeforeRun,
          context: pluginContext,
          runID: runID
        )
        installSession(transcript: sanitized, ifNeededFor: pluginContext)
        if configuration.savesTranscriptAfterFailedResponse {
          await persistAfterFailedResponse(transcript: sanitized, runID: runID)
        }
      } else if configuration.savesTranscriptAfterFailedResponse, !completedModelResponse {
        await persistAfterFailedResponse(transcript: session.transcript, runID: runID)
      }
      await failPlugins(
        CoreAgentPluginFailure(
          runID: runID,
          contextQuery: contextQuery,
          metadata: metadata,
          error: error,
          mode: sessionMode
        )
      )
      await finishRunLifecycleTools(runID: runID)
        )
        if case .failRun = plugin.failurePolicies.completion, fatalError == nil {
          fatalError = error
        }
      }
    }

    if let fatalError {
      throw fatalError
    }
  }

  private func failPlugins(_ failure: CoreAgentPluginFailure) async {
    for plugin in plugins {
      let events = await plugin.didFail(failure)
      await recordPluginEvents(events, plugin: plugin.identifier, runID: failure.runID)
    }
  }

  private func finishRunLifecycleTools(runID: UUID) async {
    for tool in runLifecycleTools {
      await tool.coreAgentRunDidFinish(runID)
    }

```

import Foundation

public struct CoreAgentGraphThreadID:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }

  public var description: String { rawValue }

  public static let `default` = CoreAgentGraphThreadID("default")
}

public struct CoreAgentGraphCheckpointNamespace:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }

  public var description: String { rawValue }

  public static let `default` = CoreAgentGraphCheckpointNamespace("default")
}

public struct CoreAgentGraphCheckpointID:
  RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public init(stringLiteral value: String) {
    self.init(value)
  }

  public var description: String { rawValue }

  public static func make() -> Self {
    CoreAgentGraphCheckpointID(UUID().uuidString.lowercased())
  }
}

public struct CoreAgentGraphPendingWrite<State: Sendable>: Sendable {
  public let nodeID: CoreAgentGraphNodeID
  public let step: Int
  public let update: State
  public let commandGoto: [CoreAgentGraphEndpoint]?

  public init(
    nodeID: CoreAgentGraphNodeID,
    step: Int,
    update: State,
    commandGoto: [CoreAgentGraphEndpoint]? = nil
  ) {
    self.nodeID = nodeID
    self.step = step
    self.update = update
    self.commandGoto = commandGoto
  }
}

extension CoreAgentGraphPendingWrite: Equatable where State: Equatable {}
extension CoreAgentGraphPendingWrite: Codable where State: Codable {}

public struct CoreAgentGraphCheckpoint<State: Sendable>: Sendable {
  public let id: CoreAgentGraphCheckpointID
  public let threadID: CoreAgentGraphThreadID
  public let namespace: CoreAgentGraphCheckpointNamespace
  public let parentCheckpointID: CoreAgentGraphCheckpointID?
  public let step: Int
  public let state: State
  public let nextNodeIDs: [CoreAgentGraphNodeID]
  public let pendingWrites: [CoreAgentGraphPendingWrite<State>]
  public let createdAt: Date

  public init(
    id: CoreAgentGraphCheckpointID = .make(),
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace = .default,
    parentCheckpointID: CoreAgentGraphCheckpointID? = nil,
    step: Int,
    state: State,
    nextNodeIDs: [CoreAgentGraphNodeID],
    pendingWrites: [CoreAgentGraphPendingWrite<State>] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.threadID = threadID
    self.namespace = namespace
    self.parentCheckpointID = parentCheckpointID
    self.step = step
    self.state = state
    self.nextNodeIDs = nextNodeIDs
    self.pendingWrites = pendingWrites
    self.createdAt = createdAt
  }
}

extension CoreAgentGraphCheckpoint: Equatable where State: Equatable {}
extension CoreAgentGraphCheckpoint: Codable where State: Codable {}

public protocol CoreAgentGraphCheckpointer<State>: Sendable {
  associatedtype State: Sendable

  func save(_ checkpoint: CoreAgentGraphCheckpoint<State>) async throws
  func checkpoint(id: CoreAgentGraphCheckpointID) async throws -> CoreAgentGraphCheckpoint<State>?
  func latest(
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace
  ) async throws -> CoreAgentGraphCheckpoint<State>?
  func history(
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace
  ) async throws -> [CoreAgentGraphCheckpoint<State>]
}

public actor InMemoryCoreAgentGraphCheckpointer<State: Sendable>:
  CoreAgentGraphCheckpointer
{
  private struct Scope: Hashable {
    let threadID: CoreAgentGraphThreadID
    let namespace: CoreAgentGraphCheckpointNamespace
  }

  private var checkpointsByID: [CoreAgentGraphCheckpointID: [CoreAgentGraphCheckpoint<State>]] = [:]
  private var checkpointsByScope: [Scope: [CoreAgentGraphCheckpoint<State>]] = [:]

  public init() {}

  public func save(_ checkpoint: CoreAgentGraphCheckpoint<State>) {
    checkpointsByID[checkpoint.id, default: []].append(checkpoint)
    let scope = Scope(threadID: checkpoint.threadID, namespace: checkpoint.namespace)
    checkpointsByScope[scope, default: []].append(checkpoint)
  }

  public func checkpoint(id: CoreAgentGraphCheckpointID) -> CoreAgentGraphCheckpoint<State>? {
    checkpointsByID[id]?.last
  }

  public func latest(
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace = .default
  ) -> CoreAgentGraphCheckpoint<State>? {
    history(threadID: threadID, namespace: namespace).first
  }

  public func history(
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace = .default
  ) -> [CoreAgentGraphCheckpoint<State>] {
    let scope = Scope(threadID: threadID, namespace: namespace)
    return checkpointsByScope[scope, default: []].reversed()
  }
}

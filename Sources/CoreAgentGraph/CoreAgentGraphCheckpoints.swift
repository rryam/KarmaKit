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
  public let taskID: CoreAgentGraphTaskID?
  public let step: Int
  public let update: State
  public let commandGoto: [CoreAgentGraphEndpoint]?
  public let commandSends: [CoreAgentGraphSend<State>]

  public init(
    nodeID: CoreAgentGraphNodeID,
    taskID: CoreAgentGraphTaskID? = nil,
    step: Int,
    update: State,
    commandGoto: [CoreAgentGraphEndpoint]? = nil,
    commandSends: [CoreAgentGraphSend<State>] = []
  ) {
    self.nodeID = nodeID
    self.taskID = taskID
    self.step = step
    self.update = update
    self.commandGoto = commandGoto
    self.commandSends = commandSends
  }
}

extension CoreAgentGraphPendingWrite: Equatable where State: Equatable {}

extension CoreAgentGraphPendingWrite: Codable where State: Codable {
  private enum CodingKeys: String, CodingKey {
    case nodeID
    case taskID
    case step
    case update
    case commandGoto
    case commandSends
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.nodeID = try container.decode(CoreAgentGraphNodeID.self, forKey: .nodeID)
    self.taskID = try container.decodeIfPresent(CoreAgentGraphTaskID.self, forKey: .taskID)
    self.step = try container.decode(Int.self, forKey: .step)
    self.update = try container.decode(State.self, forKey: .update)
    self.commandGoto = try container.decodeIfPresent(
      [CoreAgentGraphEndpoint].self,
      forKey: .commandGoto
    )
    self.commandSends =
      try container.decodeIfPresent(
        [CoreAgentGraphSend<State>].self,
        forKey: .commandSends
      ) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(nodeID, forKey: .nodeID)
    try container.encodeIfPresent(taskID, forKey: .taskID)
    try container.encode(step, forKey: .step)
    try container.encode(update, forKey: .update)
    try container.encodeIfPresent(commandGoto, forKey: .commandGoto)
    try container.encode(commandSends, forKey: .commandSends)
  }
}

public struct CoreAgentGraphCheckpoint<State: Sendable>: Sendable {
  public let id: CoreAgentGraphCheckpointID
  public let threadID: CoreAgentGraphThreadID
  public let namespace: CoreAgentGraphCheckpointNamespace
  public let parentCheckpointID: CoreAgentGraphCheckpointID?
  public let step: Int
  public let state: State
  public let nextTasks: [CoreAgentGraphPendingTask<State>]
  public let pendingWrites: [CoreAgentGraphPendingWrite<State>]
  public let createdAt: Date

  public var nextNodeIDs: [CoreAgentGraphNodeID] {
    nextTasks.map(\.nodeID)
  }

  public init(
    id: CoreAgentGraphCheckpointID = .make(),
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace = .default,
    parentCheckpointID: CoreAgentGraphCheckpointID? = nil,
    step: Int,
    state: State,
    nextNodeIDs: [CoreAgentGraphNodeID] = [],
    nextTasks: [CoreAgentGraphPendingTask<State>]? = nil,
    pendingWrites: [CoreAgentGraphPendingWrite<State>] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.threadID = threadID
    self.namespace = namespace
    self.parentCheckpointID = parentCheckpointID
    self.step = step
    self.state = state
    self.nextTasks = nextTasks ?? nextNodeIDs.map { CoreAgentGraphPendingTask($0) }
    self.pendingWrites = pendingWrites
    self.createdAt = createdAt
  }
}

extension CoreAgentGraphCheckpoint: Equatable where State: Equatable {}

extension CoreAgentGraphCheckpoint: Codable where State: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case threadID
    case namespace
    case parentCheckpointID
    case step
    case state
    case nextNodeIDs
    case nextTasks
    case pendingWrites
    case createdAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(CoreAgentGraphCheckpointID.self, forKey: .id)
    self.threadID = try container.decode(CoreAgentGraphThreadID.self, forKey: .threadID)
    self.namespace = try container.decode(
      CoreAgentGraphCheckpointNamespace.self,
      forKey: .namespace
    )
    self.parentCheckpointID = try container.decodeIfPresent(
      CoreAgentGraphCheckpointID.self,
      forKey: .parentCheckpointID
    )
    self.step = try container.decode(Int.self, forKey: .step)
    self.state = try container.decode(State.self, forKey: .state)
    let decodedTasks = try container.decodeIfPresent(
      [CoreAgentGraphPendingTask<State>].self,
      forKey: .nextTasks
    )
    let decodedNodeIDs =
      try container.decodeIfPresent(
        [CoreAgentGraphNodeID].self,
        forKey: .nextNodeIDs
      ) ?? []
    self.nextTasks = decodedTasks ?? decodedNodeIDs.map { CoreAgentGraphPendingTask($0) }
    self.pendingWrites =
      try container.decodeIfPresent(
        [CoreAgentGraphPendingWrite<State>].self,
        forKey: .pendingWrites
      ) ?? []
    self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(threadID, forKey: .threadID)
    try container.encode(namespace, forKey: .namespace)
    try container.encodeIfPresent(parentCheckpointID, forKey: .parentCheckpointID)
    try container.encode(step, forKey: .step)
    try container.encode(state, forKey: .state)
    try container.encode(nextNodeIDs, forKey: .nextNodeIDs)
    try container.encode(nextTasks, forKey: .nextTasks)
    try container.encode(pendingWrites, forKey: .pendingWrites)
    try container.encode(createdAt, forKey: .createdAt)
  }
}

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

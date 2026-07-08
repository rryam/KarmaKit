public struct CoreAgentGraphRuntimeContext: Sendable {
  public let configuration: CoreAgentGraphConfiguration
  public let runID: CoreAgentGraphRunID
  public let threadID: CoreAgentGraphThreadID
  public let checkpointNamespace: CoreAgentGraphCheckpointNamespace
  public let step: Int
  public let nodeID: CoreAgentGraphNodeID?
  public let taskID: CoreAgentGraphTaskID?
  public let command: CoreAgentGraphCommand?
  private let customEventWriter: (@Sendable (CoreAgentGraphCustomEvent) async -> Void)?

  public init(
    configuration: CoreAgentGraphConfiguration,
    runID: CoreAgentGraphRunID = .make(),
    threadID: CoreAgentGraphThreadID = .default,
    checkpointNamespace: CoreAgentGraphCheckpointNamespace = .default,
    step: Int = 0,
    nodeID: CoreAgentGraphNodeID? = nil,
    taskID: CoreAgentGraphTaskID? = nil,
    command: CoreAgentGraphCommand? = nil,
    customEventWriter: (@Sendable (CoreAgentGraphCustomEvent) async -> Void)? = nil
  ) {
    self.configuration = configuration
    self.runID = runID
    self.threadID = threadID
    self.checkpointNamespace = checkpointNamespace
    self.step = step
    self.nodeID = nodeID
    self.taskID = taskID
    self.command = command
    self.customEventWriter = customEventWriter
  }

  public var isResuming: Bool {
    command?.resumeValue != nil
  }

  public func resumeValue<Value: Codable & Sendable>(
    as type: Value.Type = Value.self
  ) throws -> Value? {
    guard let resumeValue = command?.resumeValue else { return nil }
    return try resumeValue.decode(as: type)
  }

  public func interrupt<Value: Codable & Sendable>(
    _ value: Value,
    id: CoreAgentGraphInterruptID = .make()
  ) throws -> Never {
    throw try CoreAgentGraphInterrupt(id: id, value: value)
  }

  public func emitCustomEvent<Value: Codable & Sendable>(
    _ name: String,
    value: Value
  ) async throws {
    guard let customEventWriter else { return }
    let event = try CoreAgentGraphCustomEvent(name: name, value: value)
    await customEventWriter(event)
  }

  func scoped(to nodeID: CoreAgentGraphNodeID) -> Self {
    CoreAgentGraphRuntimeContext(
      configuration: configuration,
      runID: runID,
      threadID: threadID,
      checkpointNamespace: checkpointNamespace,
      step: step,
      nodeID: nodeID,
      taskID: taskID,
      command: command,
      customEventWriter: customEventWriter
    )
  }
}

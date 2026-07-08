public struct CoreAgentGraphSend<State: Sendable>: Sendable {
  public let nodeID: CoreAgentGraphNodeID
  public let state: State
  public let taskID: CoreAgentGraphTaskID?

  public init(
    _ nodeID: CoreAgentGraphNodeID,
    state: State,
    taskID: CoreAgentGraphTaskID? = nil
  ) {
    self.nodeID = nodeID
    self.state = state
    self.taskID = taskID
  }

  public init(
    nodeID: CoreAgentGraphNodeID,
    state: State,
    taskID: CoreAgentGraphTaskID? = nil
  ) {
    self.init(nodeID, state: state, taskID: taskID)
  }
}

extension CoreAgentGraphSend: Equatable where State: Equatable {}
extension CoreAgentGraphSend: Codable where State: Codable {}

public struct CoreAgentGraphPendingTask<State: Sendable>: Sendable {
  public let nodeID: CoreAgentGraphNodeID
  public let input: State?
  public let taskID: CoreAgentGraphTaskID?
  public let source: CoreAgentGraphNodeID?

  public init(
    _ nodeID: CoreAgentGraphNodeID,
    input: State? = nil,
    taskID: CoreAgentGraphTaskID? = nil,
    source: CoreAgentGraphNodeID? = nil
  ) {
    self.nodeID = nodeID
    self.input = input
    self.taskID = taskID
    self.source = source
  }

  public init(
    nodeID: CoreAgentGraphNodeID,
    input: State? = nil,
    taskID: CoreAgentGraphTaskID? = nil,
    source: CoreAgentGraphNodeID? = nil
  ) {
    self.init(nodeID, input: input, taskID: taskID, source: source)
  }
}

extension CoreAgentGraphPendingTask: Equatable where State: Equatable {}
extension CoreAgentGraphPendingTask: Codable where State: Codable {}

extension CoreAgentGraphPendingTask {
  var isPushed: Bool {
    input != nil || source != nil
  }

  var executionSource: CoreAgentGraphNodeID {
    source ?? nodeID
  }

  func withTaskID(_ taskID: CoreAgentGraphTaskID) -> Self {
    CoreAgentGraphPendingTask(
      nodeID,
      input: input,
      taskID: taskID,
      source: source
    )
  }

  static func pushed(
    _ send: CoreAgentGraphSend<State>,
    source: CoreAgentGraphNodeID
  ) -> Self {
    CoreAgentGraphPendingTask(
      send.nodeID,
      input: send.state,
      taskID: send.taskID,
      source: source
    )
  }
}

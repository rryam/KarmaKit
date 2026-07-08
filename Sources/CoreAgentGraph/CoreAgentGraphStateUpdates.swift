public struct CoreAgentGraphStateUpdate<State: Sendable>: Sendable {
  public let update: State
  public let asNode: CoreAgentGraphNodeID
  public let taskID: CoreAgentGraphTaskID?

  public init(
    update: State,
    asNode: CoreAgentGraphNodeID,
    taskID: CoreAgentGraphTaskID? = nil
  ) {
    self.update = update
    self.asNode = asNode
    self.taskID = taskID
  }
}

extension CoreAgentGraphStateUpdate: Equatable where State: Equatable {}

extension CoreAgentCompiledGraph {
  public func updateState(
    _ update: State,
    asNode nodeID: CoreAgentGraphNodeID,
    threadID: CoreAgentGraphThreadID = .default,
    namespace: CoreAgentGraphCheckpointNamespace = .default,
    checkpointID: CoreAgentGraphCheckpointID? = nil
  ) async throws -> CoreAgentGraphCheckpoint<State> {
    try await bulkUpdateState(
      [[CoreAgentGraphStateUpdate(update: update, asNode: nodeID)]],
      threadID: threadID,
      namespace: namespace,
      checkpointID: checkpointID
    )
  }

  public func bulkUpdateState(
    _ supersteps: [[CoreAgentGraphStateUpdate<State>]],
    threadID: CoreAgentGraphThreadID = .default,
    namespace: CoreAgentGraphCheckpointNamespace = .default,
    checkpointID: CoreAgentGraphCheckpointID? = nil
  ) async throws -> CoreAgentGraphCheckpoint<State> {
    guard let checkpointer else {
      throw CoreAgentGraphRuntimeError.stateUpdateRequiresCheckpointer
    }
    guard !supersteps.isEmpty else {
      throw CoreAgentGraphRuntimeError.emptyStateUpdate
    }
    guard !supersteps.contains(where: \.isEmpty) else {
      throw CoreAgentGraphRuntimeError.emptyStateUpdate
    }

    guard
      var parent = try await baseCheckpoint(
        checkpointer: checkpointer,
        threadID: threadID,
        namespace: namespace,
        checkpointID: checkpointID
      )
    else {
      throw CoreAgentGraphRuntimeError.stateUpdateRequiresCheckpoint
    }

    var state = parent.state
    var parentCheckpointID = parent.id
    var step = parent.step

    for superstep in supersteps {
      let asNodeIDs = try validateStateUpdates(superstep)
      step += 1
      for update in superstep {
        state = try stateReducer(state, update.update)
      }
      let context = CoreAgentGraphRuntimeContext(
        configuration: configuration,
        threadID: threadID,
        checkpointNamespace: namespace,
        step: step
      )
      let nextNodeIDs = try await nextNodeIDs(after: asNodeIDs, state: state, context: context)
      parent = CoreAgentGraphCheckpoint(
        threadID: threadID,
        namespace: namespace,
        parentCheckpointID: parentCheckpointID,
        step: step,
        state: state,
        nextNodeIDs: nextNodeIDs
      )
      try await checkpointer.save(parent)
      parentCheckpointID = parent.id
    }

    return parent
  }

  private func baseCheckpoint(
    checkpointer: any CoreAgentGraphCheckpointer<State>,
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace,
    checkpointID: CoreAgentGraphCheckpointID?
  ) async throws -> CoreAgentGraphCheckpoint<State>? {
    if let checkpointID {
      return try await checkpointer.checkpoint(id: checkpointID)
    }
    return try await checkpointer.latest(threadID: threadID, namespace: namespace)
  }

  private func validateStateUpdates(
    _ updates: [CoreAgentGraphStateUpdate<State>]
  ) throws -> [CoreAgentGraphNodeID] {
    for update in updates where nodes[update.asNode] == nil {
      throw CoreAgentGraphRuntimeError.unknownStateUpdateNode(update.asNode)
    }
    return updates.map(\.asNode)
  }
}

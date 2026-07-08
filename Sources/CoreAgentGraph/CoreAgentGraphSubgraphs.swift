extension CoreAgentGraphCheckpointNamespace {
  public func appendingSubgraphNode(
    _ nodeID: CoreAgentGraphNodeID,
    taskID: CoreAgentGraphTaskID? = nil
  ) -> Self {
    var rawValue = "\(self.rawValue)/subgraphs/\(nodeID.rawValue)"
    if let taskID {
      rawValue += "/tasks/\(taskID.rawValue)"
    }
    return Self(rawValue)
  }
}

extension CoreAgentCompiledGraph {
  func executeSubgraphNode(
    _ subgraph: CoreAgentCompiledGraph<State>,
    task: CoreAgentGraphPendingTask<State>,
    order: Int,
    snapshot: State,
    context: CoreAgentGraphRuntimeContext,
    emit: StreamEmitter?
  ) async -> NodeExecutionResult {
    let namespace = context.checkpointNamespace.appendingSubgraphNode(
      task.nodeID,
      taskID: task.taskID
    )

    do {
      let update: State
      if let emit {
        update = try await streamSubgraph(
          subgraph,
          initialState: snapshot,
          threadID: context.threadID,
          namespace: namespace,
          parentStep: context.step,
          emit: emit
        )
      } else {
        update = try await subgraph.invoke(
          snapshot,
          threadID: context.threadID,
          namespace: namespace
        )
      }
      return .success(task: task, order: order, update: update)
    } catch {
      return .failure(
        task: task,
        order: order,
        error: unwrappedSubgraphError(error)
      )
    }
  }

  private func streamSubgraph(
    _ subgraph: CoreAgentCompiledGraph<State>,
    initialState: State,
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace,
    parentStep: Int,
    emit: StreamEmitter
  ) async throws -> State {
    var finalState = initialState
    for try await event in subgraph.stream(
      initialState,
      threadID: threadID,
      namespace: namespace
    ) {
      if case .values(let state, _) = event {
        finalState = state
      }
      await emit(.subgraph(namespace: namespace, event: event, step: parentStep))
    }
    return finalState
  }

  private func unwrappedSubgraphError(_ error: any Error) -> any Error {
    guard let runtimeError = error as? CoreAgentGraphRuntimeError else {
      return error
    }
    if case .interrupted(let interrupt) = runtimeError {
      return interrupt
    }
    return error
  }
}

extension CoreAgentCompiledGraph {
  func restoredCheckpoint(
    id: CoreAgentGraphCheckpointID?
  ) async throws -> CoreAgentGraphCheckpoint<State>? {
    guard let id else { return nil }
    guard let checkpoint = try await checkpointer?.checkpoint(id: id) else {
      throw CoreAgentGraphRuntimeError.checkpointNotFound(id)
    }
    return checkpoint
  }

  func saveCheckpoint(
    state: State,
    nextTasks: [CoreAgentGraphPendingTask<State>],
    pendingWrites: [CoreAgentGraphPendingWrite<State>] = [],
    step: Int,
    threadID: CoreAgentGraphThreadID,
    namespace: CoreAgentGraphCheckpointNamespace,
    parentCheckpointID: CoreAgentGraphCheckpointID?
  ) async throws -> CoreAgentGraphCheckpoint<State>? {
    guard let checkpointer else { return nil }
    let checkpoint = CoreAgentGraphCheckpoint(
      threadID: threadID,
      namespace: namespace,
      parentCheckpointID: parentCheckpointID,
      step: step,
      state: state,
      nextTasks: nextTasks,
      pendingWrites: pendingWrites
    )
    try await checkpointer.save(checkpoint)
    return checkpoint
  }

  func startTasks() -> [CoreAgentGraphPendingTask<State>] {
    startNodeIDs().map { CoreAgentGraphPendingTask($0) }
  }

  func startNodeIDs() -> [CoreAgentGraphNodeID] {
    edges.compactMap { edge -> CoreAgentGraphNodeID? in
      guard edge.source == .start, case .node(let id) = edge.target else { return nil }
      return id
    }.sorted()
  }

  func nextNodeIDs(
    after activeNodeIDs: [CoreAgentGraphNodeID],
    state: State,
    context: CoreAgentGraphRuntimeContext
  ) async throws -> [CoreAgentGraphNodeID] {
    try await nextTasks(after: activeNodeIDs, state: state, context: context).map(\.nodeID)
  }

  func nextTasks(
    after activeNodeIDs: [CoreAgentGraphNodeID],
    state: State,
    context: CoreAgentGraphRuntimeContext
  ) async throws -> [CoreAgentGraphPendingTask<State>] {
    var next: [CoreAgentGraphPendingTask<State>] = []
    let regularTargets = Dictionary(grouping: edges, by: \.source)
    let conditionals = Dictionary(grouping: conditionalEdges, by: \.source)
    let sendsBySource = Dictionary(grouping: sendEdges, by: \.source)

    for nodeID in activeNodeIDs {
      for edge in regularTargets[.node(nodeID), default: []] {
        if case .node(let target) = edge.target {
          next.append(CoreAgentGraphPendingTask(target))
        }
      }

      for conditional in conditionals[nodeID, default: []] {
        guard let selector = conditional.selector else {
          throw CoreAgentGraphRuntimeError.missingConditionalSelector(source: nodeID)
        }
        let route = try await selector(state, context.scoped(to: nodeID))
        let target = conditional.routes[route] ?? conditional.defaultTarget
        guard let target else {
          throw CoreAgentGraphRuntimeError.invalidConditionalRoute(source: nodeID, route: route)
        }
        if case .node(let targetID) = target {
          next.append(CoreAgentGraphPendingTask(targetID))
        }
      }

      for sendEdges in sendsBySource[nodeID, default: []] {
        let scopedContext = context.scoped(to: nodeID)
        let sends = try await sendEdges.selector(state, scopedContext)
        next.append(contentsOf: try sendTasks(from: sends, source: nodeID))
      }
    }

    return next
  }

  func commandTasks(
    from goto: [CoreAgentGraphEndpoint],
    source: CoreAgentGraphNodeID
  ) throws -> [CoreAgentGraphPendingTask<State>] {
    try commandNodeIDs(from: goto, source: source).map { CoreAgentGraphPendingTask($0) }
  }

  func commandNodeIDs(
    from goto: [CoreAgentGraphEndpoint],
    source: CoreAgentGraphNodeID
  ) throws -> [CoreAgentGraphNodeID] {
    let declared = Set(commandRoutes.filter { $0.source == source }.flatMap(\.targets))
    var next: [CoreAgentGraphNodeID] = []
    for target in goto {
      guard declared.contains(target) else {
        throw CoreAgentGraphRuntimeError.undeclaredCommandTarget(source: source, target: target)
      }
      if case .node(let targetID) = target {
        next.append(targetID)
      }
    }
    return next
  }

  func commandSendTasks(
    from sends: [CoreAgentGraphSend<State>],
    source: CoreAgentGraphNodeID
  ) throws -> [CoreAgentGraphPendingTask<State>] {
    let declaredTargets = Set<CoreAgentGraphNodeID>(
      commandRoutes.filter { $0.source == source }.flatMap(\.targets).compactMap { endpoint in
        guard case .node(let targetID) = endpoint else { return nil }
        return targetID
      }
    )
    return try sends.map { send in
      guard declaredTargets.contains(send.nodeID) else {
        throw CoreAgentGraphRuntimeError.undeclaredSendTarget(
          source: source,
          target: send.nodeID
        )
      }
      return CoreAgentGraphPendingTask.pushed(send, source: source)
    }
  }

  func sendTasks(
    from sends: [CoreAgentGraphSend<State>],
    source: CoreAgentGraphNodeID
  ) throws -> [CoreAgentGraphPendingTask<State>] {
    let declaredTargets = Set(sendEdges.filter { $0.source == source }.flatMap(\.targets))
    return try sends.map { send in
      guard declaredTargets.contains(send.nodeID) else {
        throw CoreAgentGraphRuntimeError.undeclaredSendTarget(
          source: source,
          target: send.nodeID
        )
      }
      return CoreAgentGraphPendingTask.pushed(send, source: source)
    }
  }

  func canonicalizeTasks(
    _ tasks: [CoreAgentGraphPendingTask<State>],
    scheduledForStep step: Int
  ) -> [CoreAgentGraphPendingTask<State>] {
    var regularByID: [CoreAgentGraphNodeID: CoreAgentGraphPendingTask<State>] = [:]
    var pushed: [CoreAgentGraphPendingTask<State>] = []
    for task in tasks {
      if task.isPushed {
        pushed.append(task)
      } else {
        regularByID[task.nodeID] = task
      }
    }
    let regular = regularByID.keys.sorted().compactMap { regularByID[$0] }
    return (regular + pushed).enumerated().map { index, task in
      guard task.isPushed else { return task }
      guard task.taskID == nil else { return task }
      return task.withTaskID(taskID(for: task, index: index, scheduledForStep: step))
    }
  }

  func pendingWriteSortKey(_ write: CoreAgentGraphPendingWrite<State>) -> String {
    write.taskID?.rawValue ?? write.nodeID.rawValue
  }

  private func taskID(
    for task: CoreAgentGraphPendingTask<State>,
    index: Int,
    scheduledForStep step: Int
  ) -> CoreAgentGraphTaskID {
    let kind = task.isPushed ? "push" : "pull"
    let source = task.source?.rawValue ?? "graph"
    return CoreAgentGraphTaskID("\(step):\(kind):\(source):\(task.nodeID.rawValue):\(index)")
  }
}

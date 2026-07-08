extension CoreAgentStateGraph.Node {
  init(
    id: CoreAgentGraphNodeID,
    operation: @escaping CoreAgentStateGraph<State>.CommandNodeOperation,
    cachePolicy: CoreAgentGraphCachePolicy<State>?,
    subgraph: CoreAgentCompiledGraph<State>?,
    deferred isDeferred: Bool
  ) {
    self.id = id
    self.operation = operation
    self.cachePolicy = cachePolicy
    self.subgraph = subgraph
    self.isDeferred = isDeferred
  }
}

extension CoreAgentStateGraph {
  public mutating func addNode(
    _ id: CoreAgentGraphNodeID,
    `defer` isDeferred: Bool,
    operation: @escaping NodeOperation
  ) throws {
    try addNode(id, cachePolicy: nil, defer: isDeferred, operation: operation)
  }

  public mutating func addNode(
    _ id: CoreAgentGraphNodeID,
    cachePolicy: CoreAgentGraphCachePolicy<State>?,
    `defer` isDeferred: Bool,
    operation: @escaping NodeOperation
  ) throws {
    try addCommandNode(id, cachePolicy: cachePolicy, defer: isDeferred) { state, context in
      .update(try await operation(state, context))
    }
  }

  public mutating func addCommandNode(
    _ id: CoreAgentGraphNodeID,
    `defer` isDeferred: Bool,
    operation: @escaping CommandNodeOperation
  ) throws {
    try addCommandNode(id, cachePolicy: nil, defer: isDeferred, operation: operation)
  }

  mutating func addCommandNode(
    _ id: CoreAgentGraphNodeID,
    cachePolicy: CoreAgentGraphCachePolicy<State>?,
    `defer` isDeferred: Bool,
    operation: @escaping CommandNodeOperation
  ) throws {
    guard nodes[id] == nil else {
      throw CoreAgentGraphCompileError.duplicateNode(id)
    }
    nodes[id] = Node(
      id: id,
      operation: operation,
      cachePolicy: cachePolicy,
      subgraph: nil,
      deferred: isDeferred
    )
  }

  public mutating func addSubgraph(
    _ id: CoreAgentGraphNodeID,
    _ subgraph: CoreAgentCompiledGraph<State>,
    `defer` isDeferred: Bool
  ) throws {
    guard nodes[id] == nil else {
      throw CoreAgentGraphCompileError.duplicateNode(id)
    }
    nodes[id] = Node(
      id: id,
      operation: { state, _ in .update(state) },
      cachePolicy: nil,
      subgraph: subgraph,
      deferred: isDeferred
    )
  }

  public mutating func addNode(
    _ id: CoreAgentGraphNodeID,
    subgraph: CoreAgentCompiledGraph<State>,
    `defer` isDeferred: Bool
  ) throws {
    try addSubgraph(id, subgraph, defer: isDeferred)
  }
}

extension CoreAgentCompiledGraph {
  func splitDeferredTasks(
    _ tasks: [CoreAgentGraphPendingTask<State>]
  ) -> (
    active: [CoreAgentGraphPendingTask<State>],
    deferred: [CoreAgentGraphPendingTask<State>]
  ) {
    let active = tasks.filter { nodes[$0.nodeID]?.isDeferred != true }
    guard !active.isEmpty else {
      return (tasks, [])
    }
    let deferred = tasks.filter { nodes[$0.nodeID]?.isDeferred == true }
    return (active, deferred)
  }
}

import Foundation

public enum CoreAgentGraphEndpoint:
  Codable, Equatable, Hashable, Sendable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  case start
  case end
  case node(CoreAgentGraphNodeID)

  public init(stringLiteral value: String) {
    self = .node(CoreAgentGraphNodeID(value))
  }

  public var description: String {
    switch self {
    case .start:
      "START"
    case .end:
      "END"
    case .node(let id):
      id.description
    }
  }
}

public enum CoreAgentGraphCompileError: Error, Equatable, Sendable {
  case duplicateNode(CoreAgentGraphNodeID)
  case invalidRecursionLimit(Int)
  case missingConditionalSelector(source: CoreAgentGraphNodeID)
  case missingEntryPoint
  case unknownEdgeSource(CoreAgentGraphNodeID)
  case unknownEdgeTarget(CoreAgentGraphNodeID)
  case unknownConditionalSource(CoreAgentGraphNodeID)
  case unknownConditionalTarget(
    source: CoreAgentGraphNodeID,
    route: String,
    target: CoreAgentGraphNodeID
  )
  case unknownCommandRouteSource(CoreAgentGraphNodeID)
  case unknownCommandRouteTarget(source: CoreAgentGraphNodeID, target: CoreAgentGraphNodeID)
  case orphanedNode(CoreAgentGraphNodeID)
}

public enum CoreAgentGraphRuntimeError: Error, Equatable, Sendable {
  case missingConditionalSelector(source: CoreAgentGraphNodeID)
  case invalidConditionalRoute(source: CoreAgentGraphNodeID, route: String)
  case checkpointNotFound(CoreAgentGraphCheckpointID)
  case emptyStateUpdate
  case interrupted(CoreAgentGraphInterrupt)
  case stateUpdateRequiresCheckpoint
  case stateUpdateRequiresCheckpointer
  case undeclaredCommandTarget(source: CoreAgentGraphNodeID, target: CoreAgentGraphEndpoint)
  case unknownCommandRouteSource(CoreAgentGraphNodeID)
  case unknownCommandRouteTarget(source: CoreAgentGraphNodeID, target: CoreAgentGraphNodeID)
  case unknownStateUpdateNode(CoreAgentGraphNodeID)
  case parallelUpdatesRequireReducer([CoreAgentGraphNodeID])
  case recursionLimitExceeded(limit: Int)
}

public enum CoreAgentGraphStreamEvent<State: Sendable>: Sendable {
  case values(State, step: Int)
  case updates(nodeID: CoreAgentGraphNodeID, update: State, step: Int)
  case taskStarted(nodeID: CoreAgentGraphNodeID, step: Int)
  case nodeCacheHit(nodeID: CoreAgentGraphNodeID, key: CoreAgentGraphCacheKey, step: Int)
  case command(nodeID: CoreAgentGraphNodeID, goto: [CoreAgentGraphEndpoint], step: Int)
  case taskCompleted(nodeID: CoreAgentGraphNodeID, step: Int)
  case taskFailed(nodeID: CoreAgentGraphNodeID, step: Int)
  case interrupted(nodeID: CoreAgentGraphNodeID, CoreAgentGraphInterrupt, step: Int)
  case custom(CoreAgentGraphCustomEvent, step: Int)
  case checkpoint(CoreAgentGraphCheckpoint<State>)
}

extension CoreAgentGraphStreamEvent: Equatable where State: Equatable {}

public struct CoreAgentGraphConfiguration: Equatable, Sendable {
  public var recursionLimit: Int

  public init(recursionLimit: Int = 25) {
    self.recursionLimit = recursionLimit
  }

  public static let `default` = CoreAgentGraphConfiguration()
}

public struct CoreAgentGraphEdge: Codable, Equatable, Sendable {
  public let source: CoreAgentGraphEndpoint
  public let target: CoreAgentGraphEndpoint

  public init(_ source: CoreAgentGraphEndpoint, _ target: CoreAgentGraphEndpoint) {
    self.source = source
    self.target = target
  }
}

public struct CoreAgentCompiledGraph<State: Sendable>: Sendable {
  public let configuration: CoreAgentGraphConfiguration
  public let nodeIDs: [CoreAgentGraphNodeID]
  public let edges: [CoreAgentGraphEdge]

  private struct NodeExecutionResult: @unchecked Sendable {
    let nodeID: CoreAgentGraphNodeID
    let update: State?
    let commandGoto: [CoreAgentGraphEndpoint]?
    let cacheKey: CoreAgentGraphCacheKey?
    let error: (any Error)?

    static func success(
      nodeID: CoreAgentGraphNodeID,
      update: State?,
      commandGoto: [CoreAgentGraphEndpoint]? = nil,
      cacheKey: CoreAgentGraphCacheKey? = nil
    ) -> Self {
      NodeExecutionResult(
        nodeID: nodeID,
        update: update,
        commandGoto: commandGoto,
        cacheKey: cacheKey,
        error: nil
      )
    }

    static func failure(nodeID: CoreAgentGraphNodeID, error: any Error) -> Self {
      NodeExecutionResult(
        nodeID: nodeID,
        update: nil,
        commandGoto: nil,
        cacheKey: nil,
        error: error
      )
    }
  }

  let nodes: [CoreAgentGraphNodeID: CoreAgentStateGraph<State>.Node]
  let conditionalEdges: [CoreAgentStateGraph<State>.ConditionalEdges]
  let commandRoutes: [CoreAgentStateGraph<State>.CommandRoutes]
  let stateReducer: CoreAgentStateGraph<State>.StateReducer
  private let permitsParallelUpdates: Bool
  let checkpointer: (any CoreAgentGraphCheckpointer<State>)?
  private let cache: (any CoreAgentGraphNodeCache<State>)?

  init(
    configuration: CoreAgentGraphConfiguration,
    nodes: [CoreAgentGraphNodeID: CoreAgentStateGraph<State>.Node],
    edges: [CoreAgentGraphEdge],
    conditionalEdges: [CoreAgentStateGraph<State>.ConditionalEdges],
    commandRoutes: [CoreAgentStateGraph<State>.CommandRoutes],
    stateReducer: @escaping CoreAgentStateGraph<State>.StateReducer,
    permitsParallelUpdates: Bool,
    checkpointer: (any CoreAgentGraphCheckpointer<State>)?,
    cache: (any CoreAgentGraphNodeCache<State>)?
  ) {
    self.configuration = configuration
    self.nodes = nodes
    self.nodeIDs = nodes.keys.sorted()
    self.edges = edges
    self.conditionalEdges = conditionalEdges
    self.commandRoutes = commandRoutes
    self.stateReducer = stateReducer
    self.permitsParallelUpdates = permitsParallelUpdates
    self.checkpointer = checkpointer
    self.cache = cache
  }

  public func invoke(
    _ initialState: State,
    threadID: CoreAgentGraphThreadID = .default,
    checkpointID: CoreAgentGraphCheckpointID? = nil,
    namespace: CoreAgentGraphCheckpointNamespace = .default,
    command: CoreAgentGraphCommand? = nil
  ) async throws -> State {
    try await run(
      initialState,
      threadID: threadID,
      checkpointID: checkpointID,
      namespace: namespace,
      command: command
    )
  }

  public func stream(
    _ initialState: State,
    threadID: CoreAgentGraphThreadID = .default,
    checkpointID: CoreAgentGraphCheckpointID? = nil,
    namespace: CoreAgentGraphCheckpointNamespace = .default,
    command: CoreAgentGraphCommand? = nil
  ) -> AsyncThrowingStream<CoreAgentGraphStreamEvent<State>, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          _ = try await run(
            initialState,
            threadID: threadID,
            checkpointID: checkpointID,
            namespace: namespace,
            command: command
          ) { event in
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func run(
    _ initialState: State,
    threadID: CoreAgentGraphThreadID,
    checkpointID: CoreAgentGraphCheckpointID?,
    namespace: CoreAgentGraphCheckpointNamespace,
    command: CoreAgentGraphCommand?,
    emitting emit: (@Sendable (CoreAgentGraphStreamEvent<State>) async -> Void)? = nil
  ) async throws -> State {
    let runID = CoreAgentGraphRunID.make()
    let restored = try await restoredCheckpoint(id: checkpointID)
    var state = restored?.state ?? initialState
    var pendingCommandTargets: [CoreAgentGraphNodeID] = []
    for pendingWrite in (restored?.pendingWrites ?? []).sorted(by: {
      if $0.step == $1.step { return $0.nodeID < $1.nodeID }
      return $0.step < $1.step
    }) {
      if let commandGoto = pendingWrite.commandGoto {
        await emit?(
          .command(nodeID: pendingWrite.nodeID, goto: commandGoto, step: pendingWrite.step))
        pendingCommandTargets.append(
          contentsOf: try commandNodeIDs(from: commandGoto, source: pendingWrite.nodeID)
        )
      }
      await emit?(.taskCompleted(nodeID: pendingWrite.nodeID, step: pendingWrite.step))
      await emit?(
        .updates(nodeID: pendingWrite.nodeID, update: pendingWrite.update, step: pendingWrite.step))
      state = try stateReducer(state, pendingWrite.update)
    }
    var frontier = restored?.nextNodeIDs ?? startNodeIDs()
    frontier.append(contentsOf: pendingCommandTargets)
    frontier = Array(Set(frontier)).sorted()
    var parentCheckpointID = restored?.id
    let firstStep = (restored?.step ?? 0) + 1
    let initialStep = restored?.step ?? 0
    var stepCommand = command

    await emit?(.values(state, step: initialStep))
    if restored == nil {
      let checkpoint = try await saveCheckpoint(
        state: state,
        nextNodeIDs: frontier,
        step: 0,
        threadID: threadID,
        namespace: namespace,
        parentCheckpointID: nil
      )
      parentCheckpointID = checkpoint?.id
      if let checkpoint {
        await emit?(.checkpoint(checkpoint))
      }
    }

    var step = firstStep
    while !frontier.isEmpty {
      guard step <= configuration.recursionLimit else {
        throw CoreAgentGraphRuntimeError.recursionLimitExceeded(
          limit: configuration.recursionLimit
        )
      }

      let activeNodeIDs = Array(Set(frontier)).sorted()
      guard permitsParallelUpdates || activeNodeIDs.count <= 1 else {
        throw CoreAgentGraphRuntimeError.parallelUpdatesRequireReducer(activeNodeIDs)
      }
      let customEventWriter: (@Sendable (CoreAgentGraphCustomEvent) async -> Void)?
      let eventStep = step
      if let emit {
        customEventWriter = { event in
          await emit(.custom(event, step: eventStep))
        }
      } else {
        customEventWriter = nil
      }
      let context = CoreAgentGraphRuntimeContext(
        configuration: configuration,
        runID: runID,
        threadID: threadID,
        checkpointNamespace: namespace,
        step: step,
        command: stepCommand,
        customEventWriter: customEventWriter
      )
      let snapshot = state

      for nodeID in activeNodeIDs {
        await emit?(.taskStarted(nodeID: nodeID, step: step))
      }

      let results = await executeNodes(
        activeNodeIDs,
        snapshot: snapshot,
        context: context
      )

      if let failure = firstFailure(in: results) {
        let failedIndex = activeNodeIDs.firstIndex(of: failure.nodeID) ?? 0
        let retryNodeIDs = Array(activeNodeIDs[failedIndex...])
        let pendingWrites = pendingWrites(
          from: results,
          before: failure.nodeID,
          step: step
        )
        let checkpoint = try await saveCheckpoint(
          state: state,
          nextNodeIDs: retryNodeIDs,
          pendingWrites: pendingWrites,
          step: step,
          threadID: threadID,
          namespace: namespace,
          parentCheckpointID: parentCheckpointID
        )
        if let checkpoint {
          await emit?(.checkpoint(checkpoint))
        }
        await emit?(.taskFailed(nodeID: failure.nodeID, step: step))
        if let interrupt = failure.error as? CoreAgentGraphInterrupt {
          await emit?(.interrupted(nodeID: failure.nodeID, interrupt, step: step))
          throw CoreAgentGraphRuntimeError.interrupted(interrupt)
        }
        if let error = failure.error {
          throw error
        }
      }

      for result in results {
        if let commandGoto = result.commandGoto {
          await emit?(.command(nodeID: result.nodeID, goto: commandGoto, step: step))
        }
        guard let update = result.update else {
          await emit?(.taskCompleted(nodeID: result.nodeID, step: step))
          continue
        }
        if let cacheKey = result.cacheKey {
          await emit?(.nodeCacheHit(nodeID: result.nodeID, key: cacheKey, step: step))
        }
        await emit?(.taskCompleted(nodeID: result.nodeID, step: step))
        await emit?(.updates(nodeID: result.nodeID, update: update, step: step))
        state = try stateReducer(state, update)
      }
      await emit?(.values(state, step: step))
      frontier = try await nextNodeIDs(after: results, state: state, context: context)
      stepCommand = nil
      let checkpoint = try await saveCheckpoint(
        state: state,
        nextNodeIDs: frontier,
        pendingWrites: [],
        step: step,
        threadID: threadID,
        namespace: namespace,
        parentCheckpointID: parentCheckpointID
      )
      parentCheckpointID = checkpoint?.id ?? parentCheckpointID
      if let checkpoint {
        await emit?(.checkpoint(checkpoint))
      }
      step += 1
    }

    return state
  }

  private func executeNodes(
    _ activeNodeIDs: [CoreAgentGraphNodeID],
    snapshot: State,
    context: CoreAgentGraphRuntimeContext
  ) async -> [NodeExecutionResult] {
    await withTaskGroup(of: NodeExecutionResult.self) { group in
      for nodeID in activeNodeIDs {
        guard let node = nodes[nodeID] else { continue }
        group.addTask {
          await executeNode(node, snapshot: snapshot, context: context)
        }
      }

      var results: [NodeExecutionResult] = []
      for await result in group {
        results.append(result)
      }
      return results.sorted { $0.nodeID < $1.nodeID }
    }
  }

  private func executeNode(
    _ node: CoreAgentStateGraph<State>.Node,
    snapshot: State,
    context: CoreAgentGraphRuntimeContext
  ) async -> NodeExecutionResult {
    let scopedContext = context.scoped(to: node.id)
    do {
      if let cache, let cachePolicy = node.cachePolicy {
        let cacheKey = try cachePolicy.key(for: snapshot, context: scopedContext)
        if let entry = try await cache.entry(forKey: cacheKey, nodeID: node.id, now: Date()) {
          return .success(nodeID: node.id, update: entry.update, cacheKey: cacheKey)
        }
        let output = try await node.operation(snapshot, scopedContext)
        let result = try nodeResult(from: output, nodeID: node.id)
        guard let update = result.update, result.commandGoto == nil else {
          return result
        }
        let storedAt = Date()
        try await cache.store(
          CoreAgentGraphCacheEntry(
            update: update,
            storedAt: storedAt,
            expiresAt: cachePolicy.ttl.map { storedAt.addingTimeInterval($0) }
          ),
          forKey: cacheKey,
          nodeID: node.id
        )
        return .success(nodeID: node.id, update: update)
      }
      let output = try await node.operation(snapshot, scopedContext)
      return try nodeResult(from: output, nodeID: node.id)
    } catch {
      return .failure(nodeID: node.id, error: error)
    }
  }

  private func nodeResult(
    from output: CoreAgentGraphNodeOutput<State>,
    nodeID: CoreAgentGraphNodeID
  ) throws -> NodeExecutionResult {
    switch output {
    case .update(let update):
      return .success(nodeID: nodeID, update: update)
    case .command(let command):
      _ = try commandNodeIDs(from: command.goto, source: nodeID)
      return .success(nodeID: nodeID, update: command.update, commandGoto: command.goto)
    }
  }

  private func firstFailure(
    in results: [NodeExecutionResult]
  ) -> NodeExecutionResult? {
    results.first { $0.error != nil }
  }

  private func pendingWrites(
    from results: [NodeExecutionResult],
    before failedNodeID: CoreAgentGraphNodeID,
    step: Int
  ) -> [CoreAgentGraphPendingWrite<State>] {
    results.prefix { $0.nodeID < failedNodeID }.compactMap { result in
      guard let update = result.update else { return nil }
      return CoreAgentGraphPendingWrite(
        nodeID: result.nodeID,
        step: step,
        update: update,
        commandGoto: result.commandGoto
      )
    }
  }

  private func restoredCheckpoint(
    id: CoreAgentGraphCheckpointID?
  ) async throws -> CoreAgentGraphCheckpoint<State>? {
    guard let id else { return nil }
    guard let checkpoint = try await checkpointer?.checkpoint(id: id) else {
      throw CoreAgentGraphRuntimeError.checkpointNotFound(id)
    }
    return checkpoint
  }

  private func saveCheckpoint(
    state: State,
    nextNodeIDs: [CoreAgentGraphNodeID],
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
      nextNodeIDs: nextNodeIDs,
      pendingWrites: pendingWrites
    )
    try await checkpointer.save(checkpoint)
    return checkpoint
  }

  private func startNodeIDs() -> [CoreAgentGraphNodeID] {
    edges.compactMap { edge -> CoreAgentGraphNodeID? in
      guard edge.source == .start, case .node(let id) = edge.target else { return nil }
      return id
    }.sorted()
  }

  private func nextNodeIDs(
    after results: [NodeExecutionResult],
    state: State,
    context: CoreAgentGraphRuntimeContext
  ) async throws -> [CoreAgentGraphNodeID] {
    var next: [CoreAgentGraphNodeID] = []
    for result in results {
      if let commandGoto = result.commandGoto {
        next.append(contentsOf: try commandNodeIDs(from: commandGoto, source: result.nodeID))
      } else {
        next.append(
          contentsOf: try await nextNodeIDs(after: [result.nodeID], state: state, context: context)
        )
      }
    }
    return Array(Set(next)).sorted()
  }

  func nextNodeIDs(
    after activeNodeIDs: [CoreAgentGraphNodeID],
    state: State,
    context: CoreAgentGraphRuntimeContext
  ) async throws -> [CoreAgentGraphNodeID] {
    var next: [CoreAgentGraphNodeID] = []
    let regularTargets = Dictionary(grouping: edges, by: \.source)
    let conditionals = Dictionary(grouping: conditionalEdges, by: \.source)

    for nodeID in activeNodeIDs {
      for edge in regularTargets[.node(nodeID), default: []] {
        if case .node(let target) = edge.target {
          next.append(target)
        }
      }

      for conditional in conditionals[nodeID, default: []] {
        guard let selector = conditional.selector else {
          throw CoreAgentGraphRuntimeError.missingConditionalSelector(source: nodeID)
        }
        let route = try await selector(state, context)
        let target = conditional.routes[route] ?? conditional.defaultTarget
        guard let target else {
          throw CoreAgentGraphRuntimeError.invalidConditionalRoute(source: nodeID, route: route)
        }
        if case .node(let targetID) = target {
          next.append(targetID)
        }
      }
    }

    return next.sorted()
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
}

public struct CoreAgentStateGraph<State: Sendable>: Sendable {
  public typealias NodeOperation =
    @Sendable (State, CoreAgentGraphRuntimeContext) async throws
    -> State
  public typealias CommandNodeOperation =
    @Sendable (State, CoreAgentGraphRuntimeContext) async throws
    -> CoreAgentGraphNodeOutput<State>
  public typealias StateReducer = @Sendable (State, State) throws -> State
  public typealias ConditionalSelector =
    @Sendable (State, CoreAgentGraphRuntimeContext) async throws
    -> String

  struct Node: Sendable {
    let id: CoreAgentGraphNodeID
    let operation: CommandNodeOperation
    let cachePolicy: CoreAgentGraphCachePolicy<State>?
  }

  struct CommandRoutes: Sendable {
    let source: CoreAgentGraphNodeID
    let targets: [CoreAgentGraphEndpoint]
  }

  struct ConditionalEdges: Sendable {
    let source: CoreAgentGraphNodeID
    let routes: [String: CoreAgentGraphEndpoint]
    let defaultTarget: CoreAgentGraphEndpoint?
    let selector: ConditionalSelector?
  }

  var nodes: [CoreAgentGraphNodeID: Node] = [:]
  var edges: [CoreAgentGraphEdge] = []
  var conditionalEdges: [ConditionalEdges] = []
  var commandRoutes: [CommandRoutes] = []
  private let stateReducer: StateReducer
  private let permitsParallelUpdates: Bool

  public init() {
    self.stateReducer = { _, update in update }
    self.permitsParallelUpdates = false
  }

  public init(_ stateReducer: @escaping StateReducer) {
    self.stateReducer = stateReducer
    self.permitsParallelUpdates = true
  }

  public init(channel: CoreAgentGraphChannel<State>) {
    self.stateReducer = channel.reduce
    self.permitsParallelUpdates = true
  }

  public mutating func addNode(
    _ id: CoreAgentGraphNodeID,
    operation: @escaping NodeOperation
  ) throws {
    try addNode(id, cachePolicy: nil, operation: operation)
  }

  public mutating func addNode(
    _ id: CoreAgentGraphNodeID,
    cachePolicy: CoreAgentGraphCachePolicy<State>?,
    operation: @escaping NodeOperation
  ) throws {
    try addCommandNode(id, cachePolicy: cachePolicy) { state, context in
      .update(try await operation(state, context))
    }
  }

  public mutating func addCommandNode(
    _ id: CoreAgentGraphNodeID,
    operation: @escaping CommandNodeOperation
  ) throws {
    try addCommandNode(id, cachePolicy: nil, operation: operation)
  }

  mutating func addCommandNode(
    _ id: CoreAgentGraphNodeID,
    cachePolicy: CoreAgentGraphCachePolicy<State>?,
    operation: @escaping CommandNodeOperation
  ) throws {
    guard nodes[id] == nil else {
      throw CoreAgentGraphCompileError.duplicateNode(id)
    }
    nodes[id] = Node(id: id, operation: operation, cachePolicy: cachePolicy)
  }

  public mutating func addCommandRoutes(
    from source: CoreAgentGraphNodeID,
    to targets: [CoreAgentGraphEndpoint]
  ) throws {
    commandRoutes.append(CommandRoutes(source: source, targets: targets))
  }

  public mutating func addEdge(
    _ source: CoreAgentGraphEndpoint,
    _ target: CoreAgentGraphEndpoint
  ) throws {
    edges.append(CoreAgentGraphEdge(source, target))
  }

  public mutating func addConditionalEdges(
    from source: CoreAgentGraphNodeID,
    routes: [String: CoreAgentGraphEndpoint],
    default defaultTarget: CoreAgentGraphEndpoint? = nil
  ) throws {
    conditionalEdges.append(
      ConditionalEdges(source: source, routes: routes, defaultTarget: defaultTarget, selector: nil)
    )
  }

  public mutating func addConditionalEdges(
    from source: CoreAgentGraphNodeID,
    routes: [String: CoreAgentGraphEndpoint],
    default defaultTarget: CoreAgentGraphEndpoint? = nil,
    _ selector: @escaping ConditionalSelector
  ) throws {
    conditionalEdges.append(
      ConditionalEdges(
        source: source,
        routes: routes,
        defaultTarget: defaultTarget,
        selector: selector
      )
    )
  }

  public func compile(
    configuration: CoreAgentGraphConfiguration = .default,
    checkpointer: (any CoreAgentGraphCheckpointer<State>)? = nil,
    cache: (any CoreAgentGraphNodeCache<State>)? = nil
  ) throws -> CoreAgentCompiledGraph<State> {
    guard configuration.recursionLimit > 0 else {
      throw CoreAgentGraphCompileError.invalidRecursionLimit(configuration.recursionLimit)
    }

    try validateKnownEdgeEndpoints()
    try validateKnownConditionalEdges()
    try validateKnownCommandRoutes()
    guard edges.contains(where: { $0.source == .start }) else {
      throw CoreAgentGraphCompileError.missingEntryPoint
    }
    try validateReachability()

    return CoreAgentCompiledGraph(
      configuration: configuration,
      nodes: nodes,
      edges: edges,
      conditionalEdges: conditionalEdges,
      commandRoutes: commandRoutes,
      stateReducer: stateReducer,
      permitsParallelUpdates: permitsParallelUpdates,
      checkpointer: checkpointer,
      cache: cache
    )
  }

}

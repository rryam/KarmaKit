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
  case unknownSendEdgeSource(CoreAgentGraphNodeID)
  case unknownSendEdgeTarget(source: CoreAgentGraphNodeID, target: CoreAgentGraphNodeID)
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
  case undeclaredSendTarget(source: CoreAgentGraphNodeID, target: CoreAgentGraphNodeID)
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
  case send(
    source: CoreAgentGraphNodeID,
    target: CoreAgentGraphNodeID,
    state: State,
    taskID: CoreAgentGraphTaskID,
    step: Int
  )
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
    let task: CoreAgentGraphPendingTask<State>
    let order: Int
    let update: State?
    let commandGoto: [CoreAgentGraphEndpoint]?
    let commandSends: [CoreAgentGraphSend<State>]
    let cacheKey: CoreAgentGraphCacheKey?
    let error: (any Error)?

    var nodeID: CoreAgentGraphNodeID {
      task.nodeID
    }

    static func success(
      task: CoreAgentGraphPendingTask<State>,
      order: Int,
      update: State?,
      commandGoto: [CoreAgentGraphEndpoint]? = nil,
      commandSends: [CoreAgentGraphSend<State>] = [],
      cacheKey: CoreAgentGraphCacheKey? = nil
    ) -> Self {
      NodeExecutionResult(
        task: task,
        order: order,
        update: update,
        commandGoto: commandGoto,
        commandSends: commandSends,
        cacheKey: cacheKey,
        error: nil
      )
    }

    static func failure(
      task: CoreAgentGraphPendingTask<State>,
      order: Int,
      error: any Error
    ) -> Self {
      NodeExecutionResult(
        task: task,
        order: order,
        update: nil,
        commandGoto: nil,
        commandSends: [],
        cacheKey: nil,
        error: error
      )
    }
  }

  let nodes: [CoreAgentGraphNodeID: CoreAgentStateGraph<State>.Node]
  let conditionalEdges: [CoreAgentStateGraph<State>.ConditionalEdges]
  let commandRoutes: [CoreAgentStateGraph<State>.CommandRoutes]
  let sendEdges: [CoreAgentStateGraph<State>.SendEdges]
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
    sendEdges: [CoreAgentStateGraph<State>.SendEdges],
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
    self.sendEdges = sendEdges
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
    var pendingCommandTasks: [CoreAgentGraphPendingTask<State>] = []
    for pendingWrite in (restored?.pendingWrites ?? []).sorted(by: {
      if $0.step == $1.step {
        return pendingWriteSortKey($0) < pendingWriteSortKey($1)
      }
      return $0.step < $1.step
    }) {
      if let commandGoto = pendingWrite.commandGoto {
        await emit?(
          .command(nodeID: pendingWrite.nodeID, goto: commandGoto, step: pendingWrite.step))
        pendingCommandTasks.append(
          contentsOf: try commandTasks(from: commandGoto, source: pendingWrite.nodeID)
        )
      }
      pendingCommandTasks.append(
        contentsOf: try commandSendTasks(
          from: pendingWrite.commandSends,
          source: pendingWrite.nodeID
        )
      )
      await emit?(.taskCompleted(nodeID: pendingWrite.nodeID, step: pendingWrite.step))
      await emit?(
        .updates(nodeID: pendingWrite.nodeID, update: pendingWrite.update, step: pendingWrite.step))
      state = try stateReducer(state, pendingWrite.update)
    }
    var frontier = restored?.nextTasks ?? startTasks()
    frontier.append(contentsOf: pendingCommandTasks)
    frontier = canonicalizeTasks(frontier, scheduledForStep: (restored?.step ?? 0) + 1)
    var parentCheckpointID = restored?.id
    let firstStep = (restored?.step ?? 0) + 1
    let initialStep = restored?.step ?? 0
    var stepCommand = command

    await emit?(.values(state, step: initialStep))
    if restored == nil {
      let checkpoint = try await saveCheckpoint(
        state: state,
        nextTasks: frontier,
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

      let activeTasks = canonicalizeTasks(frontier, scheduledForStep: step)
      guard permitsParallelUpdates || activeTasks.count <= 1 else {
        throw CoreAgentGraphRuntimeError.parallelUpdatesRequireReducer(activeTasks.map(\.nodeID))
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

      for task in activeTasks {
        await emit?(.taskStarted(nodeID: task.nodeID, step: step))
      }

      let results = await executeNodes(
        activeTasks,
        snapshot: snapshot,
        context: context
      )

      if let failure = firstFailure(in: results) {
        // `failure.order` is the task's index within `activeTasks` (assigned via
        // `activeTasks.enumerated()` in `executeNodes`). Slice `activeTasks` by that
        // order directly: `results` can be shorter than `activeTasks` when a task is
        // skipped (missing node), so a `results` position would mis-align the retry set.
        let retryTasks = Array(activeTasks[failure.order...])
        let pendingWrites = pendingWrites(
          from: results,
          before: failure.order,
          step: step
        )
        let checkpoint = try await saveCheckpoint(
          state: state,
          nextTasks: retryTasks,
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
      frontier = try await nextTasks(after: results, state: state, context: context)
      frontier = canonicalizeTasks(frontier, scheduledForStep: step + 1)
      for task in frontier where task.isPushed {
        if let source = task.source, let input = task.input, let taskID = task.taskID {
          await emit?(
            .send(
              source: source,
              target: task.nodeID,
              state: input,
              taskID: taskID,
              step: step
            )
          )
        }
      }
      stepCommand = nil
      let checkpoint = try await saveCheckpoint(
        state: state,
        nextTasks: frontier,
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
    _ activeTasks: [CoreAgentGraphPendingTask<State>],
    snapshot: State,
    context: CoreAgentGraphRuntimeContext
  ) async -> [NodeExecutionResult] {
    await withTaskGroup(of: NodeExecutionResult.self) { group in
      for (order, task) in activeTasks.enumerated() {
        guard let node = nodes[task.nodeID] else { continue }
        group.addTask {
          await executeNode(
            node,
            task: task,
            order: order,
            snapshot: task.input ?? snapshot,
            context: context
          )
        }
      }

      var results: [NodeExecutionResult] = []
      for await result in group {
        results.append(result)
      }
      return results.sorted { $0.order < $1.order }
    }
  }

  private func executeNode(
    _ node: CoreAgentStateGraph<State>.Node,
    task: CoreAgentGraphPendingTask<State>,
    order: Int,
    snapshot: State,
    context: CoreAgentGraphRuntimeContext
  ) async -> NodeExecutionResult {
    let scopedContext = context.scoped(to: node.id, taskID: task.taskID)
    do {
      if let cache, let cachePolicy = node.cachePolicy {
        let cacheKey = try cachePolicy.key(for: snapshot, context: scopedContext)
        if let entry = try await cache.entry(forKey: cacheKey, nodeID: node.id, now: Date()) {
          return .success(task: task, order: order, update: entry.update, cacheKey: cacheKey)
        }
        let output = try await node.operation(snapshot, scopedContext)
        let result = try nodeResult(from: output, task: task, order: order)
        guard let update = result.update, result.commandGoto == nil, result.commandSends.isEmpty
        else {
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
        return .success(task: task, order: order, update: update)
      }
      let output = try await node.operation(snapshot, scopedContext)
      return try nodeResult(from: output, task: task, order: order)
    } catch {
      return .failure(task: task, order: order, error: error)
    }
  }

  private func nodeResult(
    from output: CoreAgentGraphNodeOutput<State>,
    task: CoreAgentGraphPendingTask<State>,
    order: Int
  ) throws -> NodeExecutionResult {
    switch output {
    case .update(let update):
      return .success(task: task, order: order, update: update)
    case .command(let command):
      _ = try commandTasks(from: command.goto, source: task.nodeID)
      _ = try commandSendTasks(from: command.sends, source: task.nodeID)
      return .success(
        task: task,
        order: order,
        update: command.update,
        commandGoto: command.goto,
        commandSends: command.sends
      )
    }
  }

  private func firstFailure(
    in results: [NodeExecutionResult]
  ) -> NodeExecutionResult? {
    results.first { $0.error != nil }
  }

  private func pendingWrites(
    from results: [NodeExecutionResult],
    before failedOrder: Int,
    step: Int
  ) -> [CoreAgentGraphPendingWrite<State>] {
    results.prefix { $0.order < failedOrder }.compactMap { result in
      guard let update = result.update else { return nil }
      return CoreAgentGraphPendingWrite(
        nodeID: result.nodeID,
        taskID: result.task.taskID,
        step: step,
        update: update,
        commandGoto: result.commandGoto,
        commandSends: result.commandSends
      )
    }
  }

  private func nextTasks(
    after results: [NodeExecutionResult],
    state: State,
    context: CoreAgentGraphRuntimeContext
  ) async throws -> [CoreAgentGraphPendingTask<State>] {
    var next: [CoreAgentGraphPendingTask<State>] = []
    for result in results {
      if let commandGoto = result.commandGoto {
        next.append(contentsOf: try commandTasks(from: commandGoto, source: result.nodeID))
        next.append(
          contentsOf: try commandSendTasks(from: result.commandSends, source: result.nodeID))
      } else {
        let scopedContext = context.scoped(to: result.nodeID, taskID: result.task.taskID)
        next.append(
          contentsOf: try await nextTasks(
            after: [result.nodeID],
            state: state,
            context: scopedContext
          )
        )
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
  public typealias SendSelector =
    @Sendable (State, CoreAgentGraphRuntimeContext) async throws
    -> [CoreAgentGraphSend<State>]

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

  struct SendEdges: Sendable {
    let source: CoreAgentGraphNodeID
    let targets: [CoreAgentGraphNodeID]
    let selector: SendSelector
  }

  var nodes: [CoreAgentGraphNodeID: Node] = [:]
  var edges: [CoreAgentGraphEdge] = []
  var conditionalEdges: [ConditionalEdges] = []
  var commandRoutes: [CommandRoutes] = []
  var sendEdges: [SendEdges] = []
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

  public mutating func addSendEdges(
    from source: CoreAgentGraphNodeID,
    to targets: [CoreAgentGraphNodeID],
    _ selector: @escaping SendSelector
  ) throws {
    sendEdges.append(SendEdges(source: source, targets: targets, selector: selector))
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
    try validateKnownSendEdges()
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
      sendEdges: sendEdges,
      stateReducer: stateReducer,
      permitsParallelUpdates: permitsParallelUpdates,
      checkpointer: checkpointer,
      cache: cache
    )
  }

}

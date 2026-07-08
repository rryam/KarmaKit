import Foundation
import FoundationModels
import CoreAgent

public enum CoreAgentDeepTodoError: Error, Equatable, Sendable {
  case invalidStatus(String)
  case multipleWritesInTurn(String)
}

public enum CoreAgentDeepTodoStatus: String, Codable, Equatable, Sendable {
  case pending
  case inProgress = "in_progress"
  case completed
}

public struct CoreAgentDeepTodo: Codable, Equatable, Sendable {
  public let content: String
  public let status: CoreAgentDeepTodoStatus

  public init(content: String, status: CoreAgentDeepTodoStatus) {
    self.content = content
    self.status = status
  }
}

@Generable
public struct CoreAgentDeepWritableTodo: Sendable {
  public let content: String
  public let status: String

  public init(content: String, status: String) {
    self.content = content
    self.status = status
  }
}

@Generable
public struct CoreAgentDeepWriteTodosArguments: Sendable {
  public let todos: [CoreAgentDeepWritableTodo]

  public init(todos: [CoreAgentDeepTodo]) {
    self.todos = todos.map {
      CoreAgentDeepWritableTodo(content: $0.content, status: $0.status.rawValue)
    }
  }

  public init(todos: [CoreAgentDeepWritableTodo]) {
    self.todos = todos
  }

  public func typedTodos() throws -> [CoreAgentDeepTodo] {
    try todos.map { todo in
      guard let status = CoreAgentDeepTodoStatus(rawValue: todo.status) else {
        throw CoreAgentDeepTodoError.invalidStatus(todo.status)
      }
      return CoreAgentDeepTodo(content: todo.content, status: status)
    }
  }
}

public actor CoreAgentDeepTodoStore {
  private var values: [CoreAgentDeepTodo] = []

  public init() {}

  public func replace(with todos: [CoreAgentDeepTodo]) {
    values = todos
  }

  public func todos() -> [CoreAgentDeepTodo] {
    values
  }
}

public actor CoreAgentDeepTodoWriteGuard {
  private var writtenTurnIDs: Set<String> = []

  public init() {}

  public func reserveWrite(turnID: String) throws {
    guard !writtenTurnIDs.contains(turnID) else {
      throw CoreAgentDeepTodoError.multipleWritesInTurn(turnID)
    }
    writtenTurnIDs.insert(turnID)
  }

  public func reset(turnID: String) {
    writtenTurnIDs.remove(turnID)
  }

  public func resetAll() {
    writtenTurnIDs.removeAll()
  }
}

public struct CoreAgentDeepTodoTool: Tool, CoreAgentRunLifecycleTool {
  public let name = "write_todos"
  public let description =
    "Replaces the current structured task list. Todo status must be pending, in_progress, or completed."

  private let store: CoreAgentDeepTodoStore
  private let writeGuard: CoreAgentDeepTodoWriteGuard?
  private let turnID: (@Sendable () async -> String)?

  public init(
    store: CoreAgentDeepTodoStore,
    writeGuard: CoreAgentDeepTodoWriteGuard? = nil,
    turnID: (@Sendable () async -> String)? = nil
  ) {
    self.store = store
    self.writeGuard = writeGuard
    self.turnID = turnID
  }

  @concurrent
  public func call(arguments: CoreAgentDeepWriteTodosArguments) async throws -> String {
    if let writeGuard, let scopedTurnID = await currentTurnID() {
      try await writeGuard.reserveWrite(turnID: scopedTurnID)
    }
    let todos = try arguments.typedTodos()
    await store.replace(with: todos)
    return "COREAGENT_DEEP_TODOS_UPDATED_V1 count=\(todos.count)"
  }

  public func coreAgentRunDidFinish(_ runID: UUID) async {
    await resetTurnScope(runID.uuidString.lowercased())
  }

  public func resetTurnScope(_ turnID: String) async {
    await writeGuard?.reset(turnID: turnID)
  }

  private func currentTurnID() async -> String? {
    if let turnID {
      return await turnID()
    }
    return CoreAgentToolInvocation.current?.runID.uuidString.lowercased()
  }
}

public struct CoreAgentDeepTodosPlugin: CoreAgentSessionPlugin {
  public let identifier: String
  public let todoTool: CoreAgentDeepTodoTool

  public var tools: [any Tool] {
    [todoTool]
  }

  public init(
    identifier: String = "coreagent.deep.todos",
    store: CoreAgentDeepTodoStore = CoreAgentDeepTodoStore(),
    writeGuard: CoreAgentDeepTodoWriteGuard = CoreAgentDeepTodoWriteGuard()
  ) {
    self.identifier = identifier
    self.todoTool = CoreAgentDeepTodoTool(
      store: store,
      writeGuard: writeGuard
    )
  }

  public func didComplete(_ completion: CoreAgentPluginCompletion) async throws
    -> [CoreAgentPluginEvent]
  {
    await todoTool.resetTurnScope(completion.runID.uuidString.lowercased())
    return []
  }

  public func didFail(_ failure: CoreAgentPluginFailure) async -> [CoreAgentPluginEvent] {
    await todoTool.resetTurnScope(failure.runID.uuidString.lowercased())
    return []
  }
}

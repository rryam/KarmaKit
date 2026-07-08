import CoreAgent
import CoreAgentDeep
import CoreAgentTestSupport
import Foundation
import FoundationModels
import Testing

@Suite("CoreAgentDeep todos")
struct CoreAgentDeepTodoTests {
  @Test("Exposes Deep Agents compatible todo tool literals")
  func exposesTodoToolLiterals() {
    let store = CoreAgentDeepTodoStore()
    let tool = CoreAgentDeepTodoTool(store: store)

    #expect(tool.name == "write_todos")
    #expect(CoreAgentDeepTodoStatus.pending.rawValue == "pending")
    #expect(CoreAgentDeepTodoStatus.inProgress.rawValue == "in_progress")
    #expect(CoreAgentDeepTodoStatus.completed.rawValue == "completed")
  }

  @Test("write_todos replaces the persisted typed todo list")
  func writeTodosReplacesTypedState() async throws {
    let store = CoreAgentDeepTodoStore()
    let tool = CoreAgentDeepTodoTool(store: store)
    let todos = [
      CoreAgentDeepTodo(content: "Inspect sources", status: .completed),
      CoreAgentDeepTodo(content: "Implement Swift port", status: .inProgress),
    ]

    let result = try await tool.call(arguments: CoreAgentDeepWriteTodosArguments(todos: todos))

    #expect(result == "COREAGENT_DEEP_TODOS_UPDATED_V1 count=2")
    #expect(await store.todos() == todos)
  }

  @Test("write_todos rejects invalid model status strings before mutating state")
  func writeTodosRejectsInvalidStatus() async throws {
    let store = CoreAgentDeepTodoStore()
    let tool = CoreAgentDeepTodoTool(store: store)

    await #expect(throws: CoreAgentDeepTodoError.invalidStatus("blocked")) {
      _ = try await tool.call(
        arguments: CoreAgentDeepWriteTodosArguments(
          todos: [
            CoreAgentDeepWritableTodo(content: "Review", status: "blocked")
          ]
        )
      )
    }
    #expect(await store.todos().isEmpty)
  }

  @Test("write_todos guard rejects a second write in the same turn scope")
  func writeTodosGuardRejectsSecondWriteInSameTurn() async throws {
    let store = CoreAgentDeepTodoStore()
    let turnScope = MutableTodoTurnScope("turn-1")
    let tool = CoreAgentDeepTodoTool(
      store: store,
      writeGuard: CoreAgentDeepTodoWriteGuard(),
      turnID: { await turnScope.value() }
    )

    _ = try await tool.call(
      arguments: CoreAgentDeepWriteTodosArguments(
        todos: [CoreAgentDeepTodo(content: "Plan", status: .completed)]
      )
    )
    await #expect(throws: CoreAgentDeepTodoError.multipleWritesInTurn("turn-1")) {
      _ = try await tool.call(
        arguments: CoreAgentDeepWriteTodosArguments(
          todos: [CoreAgentDeepTodo(content: "Rewrite", status: .inProgress)]
        )
      )
    }

    #expect(await store.todos() == [CoreAgentDeepTodo(content: "Plan", status: .completed)])
  }

  @Test("write_todos guard consumes the turn scope before status validation")
  func writeTodosGuardConsumesTurnScopeBeforeValidation() async throws {
    let store = CoreAgentDeepTodoStore()
    let turnScope = MutableTodoTurnScope("turn-1")
    let tool = CoreAgentDeepTodoTool(
      store: store,
      writeGuard: CoreAgentDeepTodoWriteGuard(),
      turnID: { await turnScope.value() }
    )

    await #expect(throws: CoreAgentDeepTodoError.invalidStatus("blocked")) {
      _ = try await tool.call(
        arguments: CoreAgentDeepWriteTodosArguments(
          todos: [
            CoreAgentDeepWritableTodo(content: "Invalid first attempt", status: "blocked")
          ]
        )
      )
    }
    await #expect(throws: CoreAgentDeepTodoError.multipleWritesInTurn("turn-1")) {
      _ = try await tool.call(
        arguments: CoreAgentDeepWriteTodosArguments(
          todos: [CoreAgentDeepTodo(content: "Correction", status: .pending)]
        )
      )
    }

    #expect(await store.todos().isEmpty)
  }

  @Test("write_todos guard allows a new write in a new turn scope")
  func writeTodosGuardAllowsNewTurn() async throws {
    let store = CoreAgentDeepTodoStore()
    let turnScope = MutableTodoTurnScope("turn-1")
    let tool = CoreAgentDeepTodoTool(
      store: store,
      writeGuard: CoreAgentDeepTodoWriteGuard(),
      turnID: { await turnScope.value() }
    )

    _ = try await tool.call(
      arguments: CoreAgentDeepWriteTodosArguments(
        todos: [CoreAgentDeepTodo(content: "First", status: .completed)]
      )
    )
    await turnScope.set("turn-2")
    _ = try await tool.call(
      arguments: CoreAgentDeepWriteTodosArguments(
        todos: [CoreAgentDeepTodo(content: "Second", status: .inProgress)]
      )
    )

    #expect(await store.todos() == [CoreAgentDeepTodo(content: "Second", status: .inProgress)])
  }

  @Test("write_todos allows multiple unmanaged direct calls when no turn scope is available")
  func writeTodosAllowsMultipleUnmanagedDirectCallsWithoutTurnScope() async throws {
    let store = CoreAgentDeepTodoStore()
    let tool = CoreAgentDeepTodoTool(
      store: store,
      writeGuard: CoreAgentDeepTodoWriteGuard(),
      turnID: nil
    )

    _ = try await tool.call(
      arguments: CoreAgentDeepWriteTodosArguments(
        todos: [CoreAgentDeepTodo(content: "First direct call", status: .completed)]
      )
    )
    _ = try await tool.call(
      arguments: CoreAgentDeepWriteTodosArguments(
        todos: [CoreAgentDeepTodo(content: "Second direct call", status: .inProgress)]
      )
    )

    #expect(
      await store.todos() == [CoreAgentDeepTodo(content: "Second direct call", status: .inProgress)]
    )
  }

  @Test("write_todos lifecycle cleanup clears a finished run scope")
  func writeTodosLifecycleCleanupClearsFinishedRunScope() async throws {
    let store = CoreAgentDeepTodoStore()
    let runID = UUID()
    let turnScope = MutableTodoTurnScope(runID.uuidString.lowercased())
    let tool = CoreAgentDeepTodoTool(
      store: store,
      writeGuard: CoreAgentDeepTodoWriteGuard(),
      turnID: { await turnScope.value() }
    )

    _ = try await tool.call(
      arguments: CoreAgentDeepWriteTodosArguments(
        todos: [CoreAgentDeepTodo(content: "First run write", status: .pending)]
      )
    )
    await tool.coreAgentRunDidFinish(runID)
    _ = try await tool.call(
      arguments: CoreAgentDeepWriteTodosArguments(
        todos: [CoreAgentDeepTodo(content: "Same run scope after cleanup", status: .completed)]
      )
    )

    #expect(
      await store.todos() == [
        CoreAgentDeepTodo(content: "Same run scope after cleanup", status: .completed)
      ])
  }

  @Test("Todos plugin binds write_todos to the CoreAgent run turn scope")
  func todosPluginBindsWritesToCoreAgentRunScope() async throws {
    let store = CoreAgentDeepTodoStore()
    let plugin = CoreAgentDeepTodosPlugin(store: store)
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        id: "todos-first",
        name: "write_todos",
        argumentsJSON: #"{"todos":[{"content":"Plan the work","status":"pending"}]}"#
      ),
      .toolCall(
        id: "todos-second",
        name: "write_todos",
        argumentsJSON: #"{"todos":[{"content":"Rewrite the plan","status":"in_progress"}]}"#
      ),
    ])
    let session = try CoreAgentSession(
      model: model,
      toolConfiguration: .init(policy: AllowAllCoreAgentToolPolicy()),
      plugins: [plugin]
    )

    let thrown = await #expect(throws: (any Error).self) {
      _ = try await session.respond(to: "Write todos twice in one model turn.")
    }
    let toolCallError = try #require(thrown as? LanguageModelSession.ToolCallError)
    let turnID = try #require(todoTurnID(from: toolCallError.underlyingError))
    let run = try #require(await session.lastRun())

    #expect(turnID == run.id.uuidString.lowercased())
    #expect(
      await store.todos() == [
        CoreAgentDeepTodo(content: "Plan the work", status: .pending)
      ])
  }

  @Test("Todos plugin allows one write per later CoreAgent run")
  func todosPluginAllowsOneWritePerLaterCoreAgentRun() async throws {
    let store = CoreAgentDeepTodoStore()
    let plugin = CoreAgentDeepTodosPlugin(store: store)
    let model = RecordedLanguageModel(steps: [
      .toolCall(
        id: "todos-first-run",
        name: "write_todos",
        argumentsJSON: #"{"todos":[{"content":"First run","status":"pending"}]}"#
      ),
      .response(text: "first complete"),
      .toolCall(
        id: "todos-second-run",
        name: "write_todos",
        argumentsJSON: #"{"todos":[{"content":"Second run","status":"completed"}]}"#
      ),
      .response(text: "second complete"),
    ])
    let session = try CoreAgentSession(
      model: model,
      toolConfiguration: .init(policy: AllowAllCoreAgentToolPolicy()),
      plugins: [plugin]
    )

    _ = try await session.respond(to: "Write todos once.")
    _ = try await session.respond(to: "Write todos once again.")

    #expect(
      await store.todos() == [
        CoreAgentDeepTodo(content: "Second run", status: .completed)
      ])
  }
}

private func todoTurnID(from error: any Error) -> String? {
  guard case CoreAgentDeepTodoError.multipleWritesInTurn(let turnID) = error else {
    return nil
  }
  return turnID
}

private actor MutableTodoTurnScope {
  private var current: String

  init(_ current: String) {
    self.current = current
  }

  func value() -> String {
    current
  }

  func set(_ value: String) {
    current = value
  }
}

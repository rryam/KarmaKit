public struct CoreAgentGraphNodeCommand<State: Sendable>: Sendable {
  public let update: State?
  public let goto: [CoreAgentGraphEndpoint]

  public init(
    update: State? = nil,
    goto: [CoreAgentGraphEndpoint]
  ) {
    self.update = update
    self.goto = goto
  }
}

extension CoreAgentGraphNodeCommand: Equatable where State: Equatable {}

public enum CoreAgentGraphNodeOutput<State: Sendable>: Sendable {
  case update(State)
  case command(CoreAgentGraphNodeCommand<State>)

  public static func command(
    update: State? = nil,
    goto: [CoreAgentGraphEndpoint]
  ) -> Self {
    .command(CoreAgentGraphNodeCommand(update: update, goto: goto))
  }
}

extension CoreAgentGraphNodeOutput: Equatable where State: Equatable {}

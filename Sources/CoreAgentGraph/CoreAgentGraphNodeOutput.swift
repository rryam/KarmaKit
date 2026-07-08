public struct CoreAgentGraphNodeCommand<State: Sendable>: Sendable {
  public let update: State?
  public let goto: [CoreAgentGraphEndpoint]
  public let sends: [CoreAgentGraphSend<State>]

  public init(
    update: State? = nil,
    goto: [CoreAgentGraphEndpoint] = [],
    sends: [CoreAgentGraphSend<State>] = []
  ) {
    self.update = update
    self.goto = goto
    self.sends = sends
  }
}

extension CoreAgentGraphNodeCommand: Equatable where State: Equatable {}

public enum CoreAgentGraphNodeOutput<State: Sendable>: Sendable {
  case update(State)
  case command(CoreAgentGraphNodeCommand<State>)

  public static func command(
    update: State? = nil,
    goto: [CoreAgentGraphEndpoint] = [],
    sends: [CoreAgentGraphSend<State>] = []
  ) -> Self {
    .command(CoreAgentGraphNodeCommand(update: update, goto: goto, sends: sends))
  }
}

extension CoreAgentGraphNodeOutput: Equatable where State: Equatable {}

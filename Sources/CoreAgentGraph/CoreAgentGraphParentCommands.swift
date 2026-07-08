struct CoreAgentGraphParentCommand<State: Sendable>: Error, Sendable {
  let update: State?
  let goto: [CoreAgentGraphEndpoint]
  let sends: [CoreAgentGraphSend<State>]
}

extension CoreAgentGraphEndpoint {
  var parentScopedTarget: CoreAgentGraphEndpoint? {
    guard case .parent(let target) = self else { return nil }
    return target
  }
}

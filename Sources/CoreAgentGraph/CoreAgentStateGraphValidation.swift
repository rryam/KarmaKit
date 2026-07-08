extension CoreAgentStateGraph {
  func validateKnownEdgeEndpoints() throws {
    for edge in edges {
      if case .node(let source) = edge.source, nodes[source] == nil {
        throw CoreAgentGraphCompileError.unknownEdgeSource(source)
      }
      if case .node(let target) = edge.target, nodes[target] == nil {
        throw CoreAgentGraphCompileError.unknownEdgeTarget(target)
      }
    }
  }

  func validateKnownConditionalEdges() throws {
    for conditional in conditionalEdges.sorted(by: { $0.source < $1.source }) {
      guard nodes[conditional.source] != nil else {
        throw CoreAgentGraphCompileError.unknownConditionalSource(conditional.source)
      }
      for route in conditional.routes.keys.sorted() {
        let target = conditional.routes[route]!
        guard case .node(let targetID) = target else {
          continue
        }
        guard nodes[targetID] != nil else {
          throw CoreAgentGraphCompileError.unknownConditionalTarget(
            source: conditional.source,
            route: route,
            target: targetID
          )
        }
      }
      if let defaultTarget = conditional.defaultTarget,
        case .node(let targetID) = defaultTarget,
        nodes[targetID] == nil
      {
        throw CoreAgentGraphCompileError.unknownConditionalTarget(
          source: conditional.source,
          route: "default",
          target: targetID
        )
      }
      if conditional.selector == nil {
        throw CoreAgentGraphCompileError.missingConditionalSelector(source: conditional.source)
      }
    }
  }

  func validateKnownCommandRoutes() throws {
    for route in commandRoutes.sorted(by: { $0.source < $1.source }) {
      guard nodes[route.source] != nil else {
        throw CoreAgentGraphCompileError.unknownCommandRouteSource(route.source)
      }
      for target in route.targets {
        guard case .node(let targetID) = target else {
          continue
        }
        guard nodes[targetID] != nil else {
          throw CoreAgentGraphCompileError.unknownCommandRouteTarget(
            source: route.source,
            target: targetID
          )
        }
      }
    }
  }

  func validateReachability() throws {
    let regularTargets = Dictionary(grouping: edges, by: \.source)
      .mapValues { $0.map(\.target) }
    let conditionalTargets = Dictionary(grouping: conditionalEdges, by: \.source)
      .mapValues { conditionals in
        conditionals.flatMap { conditional in
          var targets = conditional.routes.keys.sorted().compactMap {
            route -> CoreAgentGraphNodeID? in
            guard case .node(let id) = conditional.routes[route] else { return nil }
            return id
          }
          if let defaultTarget = conditional.defaultTarget,
            case .node(let defaultID) = defaultTarget
          {
            targets.append(defaultID)
          }
          return targets
        }
      }

    var reachable: Set<CoreAgentGraphNodeID> = []
    var frontier = regularTargets[.start, default: []].compactMap {
      endpoint -> CoreAgentGraphNodeID? in
      guard case .node(let id) = endpoint else { return nil }
      return id
    }.sorted()

    while let current = frontier.first {
      frontier.removeFirst()
      guard reachable.insert(current).inserted else { continue }

      for endpoint in regularTargets[.node(current), default: []] {
        guard case .node(let id) = endpoint else { continue }
        frontier.append(id)
      }
      frontier.append(contentsOf: conditionalTargets[current, default: []])
      for route in commandRoutes where route.source == current {
        for endpoint in route.targets {
          guard case .node(let id) = endpoint else { continue }
          frontier.append(id)
        }
      }
      frontier.sort()
    }

    for id in nodes.keys.sorted() where !reachable.contains(id) {
      throw CoreAgentGraphCompileError.orphanedNode(id)
    }
  }
}

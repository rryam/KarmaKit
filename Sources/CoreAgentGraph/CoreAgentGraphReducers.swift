import FoundationModels

public struct CoreAgentGraphChannel<Value: Sendable>: Sendable {
  public typealias Reducer = @Sendable (Value, Value) throws -> Value

  private let reducer: Reducer

  public init(_ reducer: @escaping Reducer) {
    self.reducer = reducer
  }

  public func reduce(_ current: Value, _ update: Value) throws -> Value {
    try reducer(current, update)
  }

  public static func overwrite() -> Self {
    CoreAgentGraphChannel { _, update in update }
  }
}

extension CoreAgentGraphChannel where Value: RangeReplaceableCollection {
  public static func append() -> Self {
    CoreAgentGraphChannel { current, update in
      var next = current
      next.append(contentsOf: update)
      return next
    }
  }
}

extension CoreAgentGraphChannel where Value == [Transcript.Entry] {
  public static func transcriptHistory() -> Self {
    .append()
  }
}

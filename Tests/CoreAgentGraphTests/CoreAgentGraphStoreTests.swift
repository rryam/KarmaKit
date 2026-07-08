import CoreAgentGraph
import Testing

@Suite("CoreAgentGraph store")
struct CoreAgentGraphStoreTests {
  struct Value: Sendable, Equatable {
    var label: String
  }

  @Test("Stores values by namespace and key")
  func storesValuesByNamespaceAndKey() async throws {
    let store = InMemoryCoreAgentGraphStore<Value>()

    await store.put(Value(label: "alpha"), forKey: "profile", namespace: "alpha")
    await store.put(Value(label: "beta"), forKey: "profile", namespace: "beta")

    #expect(await store.value(forKey: "profile", namespace: "alpha") == Value(label: "alpha"))
    #expect(await store.value(forKey: "profile", namespace: "beta") == Value(label: "beta"))
  }

  @Test("Lists keys in stable order")
  func listsKeysInStableOrder() async throws {
    let store = InMemoryCoreAgentGraphStore<Value>()

    await store.put(Value(label: "second"), forKey: "b", namespace: "workspace")
    await store.put(Value(label: "first"), forKey: "a", namespace: "workspace")

    #expect(await store.keys(namespace: "workspace") == ["a", "b"])
  }

  @Test("Removes values without touching other namespaces")
  func removesValuesByScope() async throws {
    let store = InMemoryCoreAgentGraphStore<Value>()
    await store.put(Value(label: "alpha"), forKey: "profile", namespace: "alpha")
    await store.put(Value(label: "beta"), forKey: "profile", namespace: "beta")

    await store.removeValue(forKey: "profile", namespace: "alpha")

    #expect(await store.value(forKey: "profile", namespace: "alpha") == nil)
    #expect(await store.value(forKey: "profile", namespace: "beta") == Value(label: "beta"))
  }
}

VERDICT: BLOCK

FINDINGS:

- P2 — SwiftData checkpointer history/latest ordering is not parity with `InMemoryCoreAgentGraphCheckpointer`.
  - `InMemoryCoreAgentGraphCheckpointer.history` returns checkpoints in reverse save order, and `latest` is the most recently saved checkpoint in that thread/namespace.
  - `CoreAgentSwiftDataGraphCheckpointer.history` sorts by:
    ```swift
    step desc, createdAt desc, storedAt desc
    ```
    This makes “latest” mean highest step/newest checkpoint timestamp, not last persisted record.
  - Real regression: saving a branch/retry/restored checkpoint with a lower step after a higher-step checkpoint will return the wrong `latest` and wrong history order compared with the in-memory implementation.
  - Concrete fix: persist an insertion ordering field, e.g. `storedSequence`/`saveOrdinal`, assigned monotonically on `save`, bind it into the integrity digest, and sort `history`/`checkpoint(id:)` by that descending. If using `storedAt`, it should be the primary ordering only if you can guarantee uniqueness and monotonicity, which `Date()` does not reliably provide.

- P2 — Duplicate checkpoint ID behavior is not deterministically equivalent to in-memory behavior.
  - In-memory stores all checkpoints for the same ID and `checkpoint(id:)` returns the last saved one.
  - SwiftData fetches by `checkpointID` and sorts by `storedAt desc, createdAt desc`. If two rows have the same or indistinguishable `storedAt`, or if created timestamps do not reflect save order, lookup can return the wrong duplicate.
  - Concrete fix: same as above: add a persisted save-order column and sort duplicate-ID lookups by that column descending. Include it in the digest so sidecar ordering metadata cannot be rewritten without invalidating the row.

TEST GAPS:

- Add a checkpointer parity test where checkpoints are saved out of step order in the same thread/namespace:
  - save step `10`
  - then save step `3`
  - assert `latest` is step `3`
  - assert `history` is `[step3, step10]`

- Add a duplicate checkpoint ID parity test:
  - save checkpoint ID `same-id` with state `A`
  - save checkpoint ID `same-id` with state `B`
  - assert `checkpoint(id:)` returns `B`
  - assert `history` includes both in reverse save order

- Add a branch lineage regression test:
  - save parent
  - save child A
  - save child B pointing at the same parent, possibly with lower/equal step or older `createdAt`
  - assert history/latest follow save order and each decoded checkpoint preserves `parentCheckpointID`

- Add a graph store replacement test:
  - `put` value `A` for namespace/key
  - `put` value `B` for the same namespace/key
  - assert `value`/`record` return only `B`
  - assert `keys(namespace:)` contains the key once

- Add a graph store corrupt-row replacement/removal regression:
  - insert a valid row for namespace/key
  - insert a corrupt or digest-invalid duplicate row for the same namespace/key
  - assert reads fail closed or choose the newest valid row according to the intended semantics
  - assert `removeValue` removes all rows for that namespace/key, including corrupt duplicates, so `keys` cannot retain ghost keys

- Add digest sidecar binding tests that mutate each sidecar field independently:
  - checkpoint `threadID`
  - checkpoint `namespace`
  - checkpoint `parentCheckpointID`
  - checkpoint `step`
  - checkpoint `createdAt`
  - store `namespace`
  - store `key`
  - store `updatedAt`
  - assert readback returns `nil` rather than trusting mismatched metadata.
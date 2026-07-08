BLOCK: protected-region enforcement is bypassable when the same protected marker pair appears more than once in a skill body.

`editsProtectedRegion` only protects the first matched range returned by `protectedRange(for:in:)`:

```swift
let protectedRanges = regions.compactMap { protectedRange(for: $0, in: body) }
```

`protectedRange` finds only the first `startMarker` and the next `endMarker`. If the body contains two `<!-- coreagent-slow-update:start --> ... <!-- coreagent-slow-update:end -->` blocks, edits inside the second block are not detected and can be accepted by both the sleep optimizer and direct optimizer when policy includes `.skillOptSlowUpdate`.

Concrete failing shape:

```swift
body = """
<!-- coreagent-slow-update:start -->
Protected A
<!-- coreagent-slow-update:end -->

<!-- coreagent-slow-update:start -->
Protected B
<!-- coreagent-slow-update:end -->
"""

candidateEdits: [
  .replace(target: "Protected B", replacement: "Overwrite")
]
policy.protectedRegions: [.skillOptSlowUpdate]
```

This should be rejected as `.protectedRegionMutation`, but current code accepts it because only the first protected range is checked. Fix by collecting all marker-delimited ranges for each protected region, or fail closed on duplicate/malformed markers.

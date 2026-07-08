BLOCK: protected-region policy still has a concrete bypass for `append` when a protected region is unterminated.

`protectedRanges(for:in:)` intentionally treats a missing end marker as protecting from the start marker through `body.endIndex`:

```swift
ranges.append(start.lowerBound..<body.endIndex)
```

But `editsProtectedRegion(...)` ignores all `.append` edits:

```swift
guard case .replace(let target, _) = edit,
  let targetRange = body.range(of: target)
else {
  continue
}
```

So a skill body like:

```markdown
Use Swift Testing.
<!-- coreagent-slow-update:start -->
Protected slow-update memory.
```

with policy:

```swift
CoreAgentSkillOptimizationPolicy(protectedRegions: [.skillOptSlowUpdate])
```

will still accept:

```swift
.append("\nOverwrite/extend protected memory.")
```

Because the protected region is considered open to EOF, appending at EOF mutates protected content but is not rejected.

This should be fixed before treating the sleep/recursive optimizer slice as done. A likely fix is for `editsProtectedRegion` to reject `.append` whenever any protected range reaches `body.endIndex`, or more generally to model append as an insertion at `body.endIndex` and treat insertion into an open protected region as protected-region mutation.

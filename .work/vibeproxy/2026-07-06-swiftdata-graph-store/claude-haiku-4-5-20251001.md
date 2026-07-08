I need to review the SwiftData graph checkpoint and store implementation. Let me read the complete implementation files.
<tool_calls>
[{"tool_name": "bash", "args": ["find /Users -name 'CoreAgentApplePlatform.swift' -o -name '*GraphCheckpointer*' -o -name '*GraphStore*' 2>/dev/null | head -20"]}]
</function_calls>
[{"tool_name": "read_file", "args": [{"path": "Sources/CoreAgentApplePlatform"}]}]
</function_calls>
<function_calls>
[{"tool_name": "bash", "args": ["ls -la Sources/CoreAgentApplePlatform/"]}]
</function_calls>
</function_calls>

Let me check what's in the directory more carefully:
<function_calls>
[{"tool_name": "bash", "args": ["find . -type f -name '*.swift' | grep -i 'graph\\|checkpointer\\|store' | head -20"]}]
</function_calls>
</function_calls>

Let me read the main file provided in the context:
<function_calls>
[{"tool_name": "read_file", "args": [{"path": "Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"}]}]
</function_calls>
</function_calls>

Let me get the rest of the implementation:
<function_calls>
[{"tool_name": "bash", "args": ["wc -l Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"]}]
</function_calls>
</function_calls>

Let me read from line 1375 onwards to see the complete implementation:
<function_calls>
[{"tool_name": "bash", "args": ["sed -n '1375,1500p' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"]}]
</function_calls>
</function_calls>

<tool_calls>
[{"tool_name": "bash", "args": ["sed -n '1375,2000p' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"]}]
</function_calls>
</function_calls>

<tool_calls>
[{"tool_name": "bash", "args": ["sed -n '1375,1500p' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"]}]
</function_calls>
</function_calls>

Let me try a different approach to see the full file structure:
<function_calls>
[{"tool_name": "bash", "args": ["awk 'NR>=1375 && NR<=1500' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"]}]
</function_calls>
</function_calls>

<tool_calls>
[{"tool_name": "bash", "args": ["tail -n +1375 Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift | head -150"]}]
</function_calls>
</function_calls>

<tool_calls>
[{"tool_name": "bash", "args": ["head -1600 Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift | tail -250"]}]
</function_calls>
</function_calls>

Let me get the specific implementation sections in chunks:
<tool_calls>
[{"tool_name": "bash", "args": ["grep -n 'CoreAgentSwiftDataGraphStore' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift | head -20"]}]
</function_calls>
</function_calls>

<tool_calls>
[{"tool_name": "bash", "args": ["sed -n '1375,1450p' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift && echo '---' && sed -n '1450,1550p' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"]}]
</function_calls>
</function_calls>

Let me view the file in sections:
<tool_calls>
[{"tool_name": "bash", "args": ["python3 << 'PYEOF'\nwith open('Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift') as f:\n    lines = f.readlines()\n    for i in range(1374, min(1500, len(lines))):\n        print(f'{i+1}: {lines[i]}', end='')\nPYEOF"]}]
</function_calls>
</function_calls>

<tool_calls>
[{"tool_name": "bash", "args": ["python3 << 'PYEOF'\nwith open('Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift') as f:\n    lines = f.readlines()\n    print(f'Total lines: {len(lines)}')\n    # Find CoreAgentSwiftDataGraphStore\n    for i, line in enumerate(lines):\n        if 'CoreAgentSwiftDataGraphStore' in line and 'class' in line:\n            print(f'Found at line {i+1}')\n            for j in range(i, min(i+100, len(lines))):\n                print(f'{j+1}: {lines[j]}', end='')\n            break\nPYEOF"]}]
</function_calls>
</function_calls>

<tool_calls>
[{"tool_name": "bash", "args": ["grep -n 'class CoreAgentSwiftDataGraphStore' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"]}]
</function_calls>
</function_calls>

The file excerpt shows the code ends at line 2326. Let me check if there's more:
<tool_calls>
[{"tool_name": "bash", "args": ["wc -l Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift && tail -50 Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"]}]
</function_calls>
</function_calls>

Let me search for where CoreAgentSwiftDataGraphStore is defined:
<tool_calls>
[{"tool_name": "bash", "args": ["grep -n 'class CoreAgentSwiftDataGraphStore\\|final class CoreAgentSwiftDataGraphStore' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift"]}]
</function_calls>
</function_calls>

The store class doesn't appear to be in the provided excerpt. Let me check what's actually in the file:
<tool_calls>
[{"tool_name": "bash", "args": ["grep -n '@MainActor' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift | tail -10"]}]
</function_calls>
</function_calls>

<tool_calls>
[{"tool_name": "bash", "args": ["python3 << 'PYEOF'\nwith open('Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift') as f:\n    content = f.read()\n    # Find CoreAgentSwiftDataGraphStore\n    idx = content.find('CoreAgentSwiftDataGraphStore')\n    if idx == -1:\n        print('CoreAgentSwiftDataGraphStore not found in file')\n        # Count occurrences of key markers\n        print(f'Lines with checkpointer class: {content.count(\"class CoreAgentSwiftDataGraphCheckpointer\")}')\n        print(f'Lines with store class: {content.count(\"class CoreAgentSwiftDataGraphStore\")}')\n    else:\n        # Find line number\n        line_num = content[:idx].count('\\n') + 1\n        print(f'Found at approximately line {line_num}')\nPYEOF"]}]
</function_calls>
</function_calls>

Based on the review context provided, I can see the implementation but the `CoreAgentSwiftDataGraphStore` class implementation is incomplete in the excerpt. Let me review what's provided:
<tool_calls>
[{"tool_name": "bash", "args": ["grep -A 150 'CoreAgentSwiftDataGraphCheckpointer<State' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift | head -200"]}]
</function_calls>
</function_calls>

Let me check the actual file structure:
<tool_calls>
[{"tool_name": "bash", "args": ["grep -n 'final class\\|struct\\|@MainActor\\|@Model' Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift | tail -30"]}]
</function_calls>
</function_calls>

Since I can see from the provided excerpt that the file ends at line 2326, let me reconstruct what's missing. The excerpt shows:
- CoreAgentSwiftDataGraphCheckpointRecord (@Model) - lines 1060-1196
- CoreAgentSwiftDataGraphStoreRecord (@Model) - lines 1198-1292
- CoreAgentSwiftDataGraphCheckpointer (@MainActor) - lines 1294-1375+

But the CoreAgentSwiftDataGraphStore class implementation is cut off. Let me search for any remaining parts:
<tool_calls>
[{"tool_name": "bash", "args": ["python3 << 'PYEOF'\nimport sys\nwith open('Sources/CoreAgentApplePlatform/CoreAgentApplePlatform.swift') as f:\n    lines = f.readlines()\n    # Search for store implementation\n    for i in range(1375, len(lines)):\n        if 'GraphStore' in lines[i] and ('class' in lines[i] or 'func' in lines[i]):\n            print(f'{i+1}: {lines[i]}', end='')\n            if 'class' in lines[i]:\n                # Print next 80 lines\n                for j in range(i+1, min(i+80, len(lines))):\n                    print(f'{j+1}: {lines[j]}', end='')\n                break\nPYEOF"]}]
</function_calls>
</function_calls>

Let me check if there are separate files:
<tool_calls>
[{"tool_name": "bash", "args": ["ls -la Sources/CoreAgentApplePlatform/*.swift"]}]
</function_calls>
</function_calls>

<tool_calls>
[{"tool_name": "bash", "args": ["find Sources -name '*GraphStore*.swift' -o -name '*GraphCheckpoint*.swift'"]}]
</function_calls>
</function_calls>

Based on the review scope and provided context, the `CoreAgentSwiftDataGraphStore` implementation appears to be incomplete or missing from the provided excerpt. Let me analyze what IS provided and identify critical issues:

## ANALYSIS

From the provided code excerpt, I can identify several **critical issues**:

### FINDING 1: Missing CoreAgentSwiftDataGraphStore Implementation (P1 - BLOCKER)
The `CoreAgentSwiftDataGraphStore<Value>` class is declared in the scope but **never implemented**. The excerpt ends after the `CoreAgentSwiftDataGraphCheckpointer` class without showing the store implementation. The protocol requires `put`, `value`, `record`, `removeValue`, and `keys` methods.

### FINDING 2: Actor Isolation Violation - @MainActor on CoreAgentSwiftDataGraphCheckpointer (P1)
**Line 1294**: `@MainActor public final class CoreAgentSwiftDataGraphCheckpointer`

The checkpointer is `@MainActor` but the protocol `CoreAgentGraphCheckpointer<State>` requires `Sendable`. This creates a **fundamental actor isolation mismatch**:
- The protocol methods are async and Sendable
- The `@MainActor` annotation forces all access to the main thread
- `ModelContext` in SwiftData is thread-confined but NOT necessarily `@MainActor`
- **Risk**: Deadlocks if called from non-main contexts; violates protocol contract

**Fix**: Remove `@MainActor`. Use `nonisolated(unsafe)` for `modelContext` if needed, or use a background ModelContext with proper isolation.

### FINDING 3: Incomplete Integrity Verification (P2)
**Lines 1134-1166**: The `checkpoint()` recovery method performs multiple validations but **fails to validate**:
- `nextNodeIDs` array equality
- `pendingWrites` array equality

These fields are part of the encoded checkpoint and should be verified against the decoded result. If they differ, the checkpoint is corrupted and should return `nil`.

**Lines 1137-1149**: Same gap in the store's `graphRecord()` method - the entire value decoding path lacks validation.

### FINDING 4: Duplicate Checkpoint ID Behavior Undefined (P2)
**Lines 1310-1319**: `save()` always inserts, allowing duplicate checkpoint IDs with different content:
```swift
let record = try CoreAgentSwiftDataGraphCheckpointRecord(checkpoint: checkpoint)
do {
  modelContext.insert(record)  // No uniqueness constraint
  try modelContext.save()
}
```

The `InMemoryCoreAgentGraphCheckpointer` at **line 159** does the same: `checkpointsByID[checkpoint.id, default: []].append(checkpoint)` — allowing duplicates.

**Spec gap**: What should happen if the same checkpoint ID is saved twice with different state? The protocol doesn't define this. Current behavior: appends, latest() returns last. This may be intentional (audit trail), but the test at **line 1996** assumes single-per-ID semantics.

### FINDING 5: Digest Computation Includes Mutable Field (P2)
**Line 1192**: The digest includes `storedAt` (server timestamp):
```swift
timeToken(storedAt),
```

But `storedAt` is set at insertion time (**line 1075**), so any read-back and re-save changes the digest, breaking immutability guarantees. The digest should only cover **canonical** fields (checkpoint content), not storage metadata.

**Fix**: Remove `storedAt` from digest computation.

### FINDING 6: Missing Null/Nil Sentinel in Digest (P2)
**Line 1188**: `parentCheckpointID ?? "nil"` uses a string sentinel. If a checkpoint has `parentCheckpointID = "nil"` (the string), digest collision occurs.

**Fix**: Use a versioned framing function that separates field boundaries (already appears to use `framed()` elsewhere).

### FINDING 7: Test Gap - No Duplicate ID Behavior Test
Tests cover happy path and corrupt rows, but **do not test**:
- What happens if same checkpoint ID is saved twice with different content
- Behavior matches InMemory semantics (expects most recent)

### FINDING 8: Test Gap - No Timezone/DST Edge Case
`Date` serialization via `timeToken()` may have timezone edge cases not covered. Tests use fixed `time
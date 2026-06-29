# Session Mode Implementation Status

## Purpose

This file tracks the implementation state of the understanding pipeline defined by the frozen architecture (DAS, DDS, IAG). It is updated after every completed implementation milestone and serves as the primary handoff document for future Claude Code sessions.

Do not reconstruct implementation history from git or conversation logs. Read this file instead.

---

## Architecture Status

| Layer | Status |
|-------|--------|
| DAS (DAS-000 through DAS-012) | Frozen |
| DDS (DDS-000 through DDS-009) | Frozen |
| IAG (IAG-001 through IAG-004) | Frozen |

Implementation follows these documents exactly. Architecture changes require an RFC per IAG-004 section 21.

---

## Current Implementation Phase

**Phase 3 (Write Pipeline) is complete.** The write-side foundation — types, producer execution, index maintenance, storage, and the central UpdateEngine orchestrator — is fully implemented and verified.

**Next phase: Phase 4 (Read Pipeline)** — RetrievalRuntime, then ContextAssembly, then ConsumerRuntime.

---

## Completed Subsystems

### DIRCore (M1)

- **Status**: Complete
- **Verification**: 37 tests passing, all suites green
- **Notes**: Foundation types (AtomicUnit, Epoch, WriteTransaction, etc.), cross-module protocols (DIRReadAccess, DIRWriteAccess, DemandSignalSink, EpochControl, ChangeBatchObserver). All types are Sendable and Codable where required.
- **Frozen**: Yes

### ProducerRuntime (M2)

- **Status**: Complete
- **Verification**: 35 tests passing, all suites green
- **Notes**: Producer registration, DAG construction, execution tickets, changed-output detection, failure isolation. Protocols: ExecutionDirective, ProducerRegistry, FailureReportSource.
- **Frozen**: Yes

### IndexRuntime (M3)

- **Status**: Complete
- **Verification**: 46 tests passing, all suites green
- **Notes**: Five index families (entity, graph, scope, predicate, content), batch update, DIR scan fallback when index unavailable, deferred content updates. Protocol: IndexBatchUpdate.
- **Frozen**: Yes

### StorageEngine (M8)

- **Status**: Complete
- **Verification**: 43 tests passing, all suites green
- **Notes**: Snapshot persistence with checksum validation (requires `.sortedKeys` on JSONEncoder for deterministic checksums), GC with retention policy and safety checks, grounding dependency map, content hash map, deferred queue persistence. Protocols: SnapshotPersistence, GarbageCollector, GroundingMapAccess, ContentHashMapAccess, DeferredQueuePersistence.
- **Frozen**: Yes

### UpdateEngine (M7)

- **Status**: Complete
- **Verification**: 55 tests passing across 13 suites, all green
- **Notes**:
  - UpdateActor is the central actor owning unit store, epoch counter, deferred queue, and change set processing.
  - Conforms to DIRReadAccess, DIRWriteAccess, DemandSignalSink. Does NOT conform to EpochControl (see Outstanding Issues).
  - 6-state lifecycle: Created, Reconciling, Idle, Processing, Quiescing, Terminated.
  - 8-stage synchronous pipeline in `processChangeSet()`.
  - Deferred T2 recomputation with collision detection.
  - UnitStore handles write transactions, supersession, intake validation internally.
  - IntakeValidator is stateless — validates PV-1 through PV-3, TE-1 through TE-5.
- **Frozen**: Yes

---

## Repository State

### Framework Modules (`Decode/Understanding/`)

All 8 modules from IAG-001 exist as framework targets:

| Module | Implementation |
|--------|---------------|
| DIRCore | Complete |
| ProducerRuntime | Complete |
| IndexRuntime | Complete |
| StorageEngine | Complete |
| UpdateEngine | Complete |
| RetrievalRuntime | Placeholder |
| ContextAssembly | Placeholder |
| ConsumerRuntime | Placeholder |

### Test Infrastructure (`UnderstandingTests/`)

- Test targets exist for all 8 modules plus integration tests.
- `UnderstandingTestSupport` shared library provides: `MockDIRReadAccess`, `MockDIRWriteAccess`, factory functions (`makeUnit()`, `makeEpoch()`, `makeProvenance()`, `makeAdmission()`, `makeContentHash()`).
- Each completed module has its own comprehensive mock set in its test file.

### Build System

- `project.yml` with XcodeGen. Run `xcodegen generate` after adding/removing Swift files.
- Swift 6.0, `SWIFT_STRICT_CONCURRENCY = complete`, macOS 15.0.

---

## Verification Status

| Metric | Value |
|--------|-------|
| Full app build | Succeeds (zero errors) |
| Strict concurrency | Clean (zero warnings in pipeline modules) |
| Total pipeline tests | 216 (37 + 35 + 46 + 43 + 55) |
| All tests passing | Yes |
| Implementation health | Production-quality, no stubs or scaffolding |

---

## Current Immediate Task

**Implement RetrievalRuntime (M4).**

### Specifications to Read

- **DDS-005** — Retrieval Runtime contract (five-stage evidence retrieval)
- **IAG-001 section 4** — RetrievalRuntime module boundary and dependencies
- **IAG-002** — Technology decisions relevant to retrieval
- **IAG-003 section 2** — Actor placement for retrieval
- **IAG-004 section 6** — Phase 4 entry/exit criteria

### Existing Modules to Inspect

- **DIRCore** — `DIRReadAccess` protocol (RetrievalRuntime reads committed epoch)
- **IndexRuntime** — Index query protocols (RetrievalRuntime queries indexes)
- **UnderstandingTestSupport** — Existing mocks and factories

### Modules NOT to Modify

- DIRCore, ProducerRuntime, IndexRuntime, StorageEngine, UpdateEngine — all frozen unless a genuine specification contradiction requires an RFC.

### Expected Stopping Point

RetrievalRuntime complete with tests passing, build clean, no regressions in existing tests.

---

## Remaining Implementation Order

1. **RetrievalRuntime** (M4) — Five-stage evidence retrieval *(next)*
2. **ContextAssembly** (M5) — Strategy-based context frame assembly
3. **ConsumerRuntime** (M6) — Reasoning engine management, grounding verification
4. **UnderstandingSystem** — Composition root, integration tests (Phase 5)
5. **Application Integration** — AppDependencies wiring, file monitoring bridge (Phase 6)
6. **Final Integration Testing** — End-to-end verification

Each step has a verification gate (IAG-004). No step begins until the prior gate passes.

---

## Known Implementation Decisions

These decisions are load-bearing. Future work must preserve them.

1. **Cross-module protocols are async.** All protocol methods crossing actor boundaries are `async`. This is required by Swift's actor isolation model (IAG-003 section 3.1).

2. **Actor ownership is strict.** Each actor owns its mutable state exclusively. UpdateActor owns the unit store and epoch. StorageActor owns persistence state. No shared mutable state between actors.

3. **DIR is the canonical asset.** All capabilities read from the DIR via DIRReadAccess. No module bypasses the DIR to access raw data.

4. **Index fallback to DIR scan.** When an index family is unavailable, IndexRuntime falls back to scanning the DIR directly. Consumers never fail due to missing indexes.

5. **Storage uses Codable + atomic file I/O.** No GRDB in pipeline modules (IAG-002:TI-3). SnapshotData is Codable with checksum validation.

6. **Snapshot checksums require sorted keys.** JSONEncoder must use `.sortedKeys` output formatting for deterministic checksums.

7. **No `@MainActor` in pipeline modules.** All pipeline work runs off the main thread (IAG-003 section 6.3).

8. **No `@unchecked Sendable` in production code.** Test mocks may use it; production code must not without documented justification (IAG-003 section 10.3).

9. **Test mocks are per-module.** Each test file defines its own mock implementations of dependency protocols rather than sharing across test targets. `UnderstandingTestSupport` provides only DIRCore-level mocks and factories.

---

## Outstanding Issues

**EpochControl conformance gap.** UpdateActor does not conform to the `EpochControl` protocol because the protocol defines `advanceEpoch() -> Epoch` as a nonisolated synchronous method, which cannot be satisfied by an actor that mutates state. The method exists on UpdateActor as an internal actor-isolated method. No downstream module currently depends on `EpochControl` as a conformance requirement — it is only referenced in a comment in `DIRReadAccess.swift`. If a future module needs to call `advanceEpoch()` via protocol, either the protocol needs an async variant (requiring a DIRCore RFC) or a wrapper adapter is needed. This is not a blocker for RetrievalRuntime.

No other known implementation blockers.

---

## Session Handoff

Every future Claude Code session implementing the understanding pipeline should follow this sequence:

1. **Read `CLAUDE.md`** — project rules, engineering principles, constraints.
2. **Read `SESSION_MODE_IMPLEMENTATION_STATUS.md`** (this file) — current state, next task, decisions to preserve.
3. **Read only the relevant DDS and IAG documents** for the subsystem being implemented. Do not reread the full architecture.
4. **Inspect affected repository files** — the modules being consumed and the placeholder being replaced.
5. **Implement** — production-quality code, strict concurrency, no stubs.
6. **Verify** — build clean, all tests pass (new and existing), zero regressions.
7. **Update this status document** — mark subsystem complete, update phase, advance the immediate task, record any new decisions or issues.
8. **Stop** after the subsystem is complete.

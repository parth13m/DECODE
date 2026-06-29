# DDS-008: Storage Engine Runtime

```
Document:      DDS-008
Title:         Storage Engine Runtime
Status:        Draft
Version:       0.2
Author:        Principal Engineer
Reviewers:     —
Created:       2026-06-28
Last Revised:  2026-06-28
Depends On:    DDS-000 (Design Authoring Standard), DDS-002 (DIR Runtime Model),
               DDS-007 (Update Engine Runtime)
Depended By:   (derived — see DDS dependency graph)
DAS Trace:     DAS-001, DAS-002, DAS-003, DAS-010, DAS-012
```

## Abstract

This document specifies the engineering design of the Storage Engine Runtime — the subsystem that persists the DIR to disk via epoch-aligned snapshots, loads snapshots on startup, owns and maintains the grounding dependency map, executes garbage collection based on tier-informed retention policy, and coordinates crash recovery. It realizes the storage realization architecture defined in DAS-012, the garbage collection policy of DAS-010, the tier-informed retention semantics of DAS-003, and the rebuildability guarantee of DAS-002. The Storage Engine is the sole subsystem responsible for the DIR's survival across process restarts.

## DAS Traceability

```
DAS-001: Architectural Principles
  Realized: P1 (intelligence is the canonical asset — the Storage Engine
            persists the canonical asset across restarts), P9 (incremental
            by design — reconciliation processes only changed files, not the
            full codebase), P12 (graceful degradation — crash recovery
            degrades gracefully from snapshot to full rebuild)
  Not addressed: P2, P3, P4 (DDS-001, DDS-003), P5, P6, P7 (DDS-002,
                 DDS-005, DDS-006), P8 (DDS-001, DDS-003), P10, P11
                 (DDS-001, DDS-005, DDS-006)

DAS-002: Decode Intermediate Representation
  Realized: DC-5 (rebuildable from source — full rebuild as crash recovery
            fallback), I-LC-4 (Garbage Collected terminal state — Storage
            Engine issues GC directives)
  Not addressed: I-ID-1 through I-ID-3 (DDS-002), I-LC-1, I-LC-2, I-LC-3,
                 I-LC-5 (DDS-002), I-SUB, I-PRED, I-VAL, I-TIER, I-PROV,
                 I-CONF, I-GND-1, I-GND-2, I-GND-3 (DDS-002, DDS-007),
                 I-VER-1 through I-VER-4 (DDS-002), DC-1 through DC-4
                 (DDS-002)

DAS-003: Tier Model
  Realized: TL-3 (GC eligibility by tier — tier-informed retention policy
            governs how long superseded units at each tier are retained
            before collection)
  Not addressed: TA-1 through TA-5 (DDS-001, DDS-003), I1 through I7
                 (DDS-002, DDS-001, DDS-003, DDS-005, DDS-006), TL-1
                 (DDS-007), TL-2 (DDS-002), CTD-1 through CTD-3 (DDS-007),
                 freshness contracts (DDS-007)

DAS-010: Incremental Update Model
  Realized: GC-1 (GC is removal of units no longer useful), GC-2 (tier-
            informed retention), GC-3 (GC does not block updates), GC-4
            (this DDS defines how collection is implemented)
  Not addressed: CD-1 through CD-6 (DDS-007), IP-1 through IP-6 (DDS-007),
                 CB-1 through CB-4 (DDS-007), RS-1 through RS-10 (DDS-007),
                 WR-1 through WR-7 (DDS-002, DDS-007), PU-1 through PU-5
                 (DDS-007), I1 through I8 (DDS-007, DDS-002)

DAS-012: Storage Realization
  Realized: Single-process in-memory-primary architecture (DA-1 through
            DA-7), snapshot persistence (epoch-aligned snapshots, snapshot
            atomicity, snapshot consistency, snapshot integrity, snapshot
            write timing), ephemeral index decision (I3 — indexes are not
            persisted, rebuilt on startup), grounding dependency map
            (storage-internal reverse lookup for cascade traversal),
            unit identity counter persistence, epoch counter persistence,
            content hash computation scope (raw file bytes), GC retention
            policy (GC-R1 through GC-R4), GC schedule (GC-S1 through
            GC-S3), crash recovery (scenarios 1 through 4), reconciliation
            process, full rebuild path, deferred T2 recomputation queue
            persistence, scale envelope,
            I1 (snapshot epoch correspondence), I2 (snapshot atomicity),
            I4 (reconciliation completeness), I5 (single snapshot
            persistence), I6 (grounding dependency map consistency),
            I7 (GC safety), I8 (memory boundedness)
  Not addressed: DAS-012 I3 (index ephemeral derivability — DDS-004
                 realizes the rebuild; Storage Engine simply does not
                 persist indexes)
```

## Terminology

**Snapshot** — A serialized representation of the complete DIR state at a specific epoch, written to persistent storage. Contains all active and invalidated atomic units, the epoch counter, the unit identity counter, per-file content hashes, and the deferred T2 recomputation queue. `See DAS-012`

**Reconciliation** — The process of bringing a snapshot-restored DIR into consistency with the current source state after a process restart. Compares each tracked file's current content hash against the snapshot's recorded hash. `See DAS-012`

**Grounding Dependency Map** — A reverse lookup structure mapping a unit identifier to the set of units whose provenance.inputs references it. Supports O(degree) cascade traversal for the Update Engine (DDS-007:PC-10). Built from DIR provenance records. Exclusively owned by the Storage Engine — it is a write-side structure for invalidation cascade support, not a consumer retrieval index. `See DAS-012`

**Unit Store** — The in-memory realization of the DIR, owned by the DIR Runtime (DDS-002). The Storage Engine reads the unit store for snapshot capture and writes to it for snapshot loading. `See DAS-012, DDS-002`

**Snapshot File** — The on-disk representation of a snapshot. At most two snapshot files exist at any time: the current (most recently completed) and the prior (retained until the current write completes). `See DAS-012 I5`

**Retention Period** — The number of epochs a superseded unit is retained before becoming eligible for garbage collection. Tier-dependent: T0/T1 superseded units are eligible at the next epoch; T2 superseded units are retained for a configurable number of epochs. `See DAS-012 GC-R1, GC-R2`

---

## Responsibilities

```
R1: Persist the DIR to disk via epoch-aligned snapshots.
    DAS: DAS-012 (snapshot persistence, snapshot atomicity, snapshot
         consistency, snapshot integrity), DAS-001 P1 (intelligence
         is the canonical asset — persistence ensures survival)
    Boundary: The Storage Engine serializes the DIR's unit store contents
              and metadata to disk. It does not own the unit store —
              DDS-002 does. It reads the unit store through DDS-002's
              public contracts (PC-3, bulk read).

R2: Load snapshots on startup and populate the DIR Runtime.
    DAS: DAS-012 (snapshot loading, reconciliation process, full
         rebuild path), DAS-002 DC-5 (rebuildable from source)
    Boundary: The Storage Engine reads the snapshot file, validates
              its integrity, and populates the DIR Runtime via write
              transactions (DDS-002:PC-6). It does not perform
              reconciliation — it provides the snapshot-loaded state
              to the Update Engine (DDS-007:PC-4) for reconciliation.

R3: Own and maintain the grounding dependency map exclusively.
    DAS: DAS-012 (grounding dependency map as storage-internal
         structure), DAS-010 IP-4 (cascade traversal requires
         reverse grounding lookup)
    Boundary: The Storage Engine builds the map from DIR provenance
              records on startup, maintains it incrementally during
              operation, and serves reverse grounding lookups to the
              Update Engine (DDS-007:PC-10). It does not use the map
              for invalidation decisions — DDS-007 does. The grounding
              dependency map is not an Index Runtime index family — it
              is a write-side structure serving invalidation cascade
              traversal, not consumer retrieval. Ownership remains
              permanently with the Storage Engine (DDS-008).

R4: Execute garbage collection based on tier-informed retention.
    DAS: DAS-010 GC-1 (eligibility definition), GC-2 (tier-informed
         retention), GC-3 (GC does not block updates), GC-4 (this DDS
         defines implementation), DAS-012 GC-R1 through GC-R4
         (retention policy), GC-S1 through GC-S3 (schedule),
         DAS-003 TL-3 (GC eligibility by tier)
    Boundary: The Storage Engine determines which units are eligible
              for collection and issues GC directives to the DIR
              Runtime (DDS-002:PC-7). It does not perform the status
              transition — DDS-002:PC-2 does.

R5: Manage crash recovery — detect corrupted snapshots, fall back
    to prior snapshots or full rebuild.
    DAS: DAS-012 (crash scenarios 1 through 4, snapshot integrity,
         snapshot validation), DAS-002 DC-5 (full rebuild as
         ultimate fallback)
    Boundary: The Storage Engine detects and handles snapshot
              corruption. If no valid snapshot exists, it signals the
              application lifecycle to initiate a full rebuild via the
              Producer Runtime (DDS-001:PC-5) and Update Engine
              (DDS-007:PC-1). The Storage Engine does not execute
              producers — it coordinates the recovery path.

R6: Persist and restore the deferred T2 recomputation queue.
    DAS: DAS-012 (deferred T2 recomputation queue persistence),
         DAS-010 RS-5 (T2 invalidation recording)
    Boundary: The Storage Engine includes the deferred queue in the
              snapshot and restores it on startup. It does not manage
              the queue during operation — DDS-007 does.

R7: Persist the unit identity counter and epoch counter across
    restarts.
    DAS: DAS-012 (epoch counter persistence, unit identity counter
         persistence), DAS-002 I-ID-1 (uniqueness across restarts),
         DAS-010 WR-1 (epoch definition)
    Boundary: The Storage Engine includes both counters in the
              snapshot. The DIR Runtime (DDS-002) owns these counters
              during operation — the Storage Engine merely persists
              and restores them.

R8: Track per-file content hashes for reconciliation support.
    DAS: DAS-012 (content hash computation, reconciliation process),
         DAS-002 I-VER-3 (content-addressed versioning)
    Boundary: The Storage Engine maintains the mapping of tracked
              file paths to their content hashes. The content hashes
              are recorded at each epoch and persisted in the snapshot.
              The Update Engine (DDS-007:PC-4) consumes the hash map
              during reconciliation. The content hash is computed over
              raw file bytes (DAS-012).
```

---

## Public Contracts

### Offered Contracts

```
PC-1: Snapshot Capture
  Direction:    Offered
  Counterparty: Update Engine (DDS-007, after epoch advancement),
                application lifecycle (during quiescence for final snapshot)
  Guarantee:    The Storage Engine reads the DIR Runtime's unit store
                contents, epoch counter, and unit identity counter via
                DDS-002:PC-3 (bulk read at committed epoch) and serializes
                them to a snapshot file. The snapshot also includes the
                per-file content hash map (R8) and the deferred T2
                recomputation queue (R6).

                The snapshot is written atomically: the serialized data
                is written to a temporary file, then atomically renamed
                to the canonical snapshot path (DAS-012 snapshot
                atomicity). The prior snapshot file is retained until
                the rename completes. The snapshot includes a checksum
                of its contents for validation on load (DAS-012 snapshot
                integrity).

                Every snapshot represents exactly one committed DIR epoch.
                A snapshot must never contain data spanning multiple
                committed epochs — all units, counters, content hashes,
                and deferred queue state within a single snapshot
                correspond to the same committed epoch (RI-1).

                After a successful snapshot capture, at most two snapshot
                files exist on disk: the current and the prior (DAS-012
                I5). The prior is deleted after the current is confirmed
                valid.
  Preconditions: The DIR Runtime (DDS-002) is in Operational or Quiescing
                 state (read access available). The epoch has been
                 advanced (the committed epoch is stable). No synchronous
                 pipeline is in progress.
  Failure mode: If the snapshot write fails (disk full, I/O error,
                permission denied), the prior snapshot remains valid.
                The Storage Engine logs the failure. The DIR continues
                operating normally — snapshot failure does not affect
                runtime correctness. The next epoch advancement triggers
                another snapshot attempt. If snapshot failures persist,
                the system operates without persistence until the I/O
                issue is resolved — a subsequent crash would fall back
                to the prior valid snapshot or full rebuild.

PC-2: Snapshot Loading
  Direction:    Offered
  Counterparty: Application lifecycle (during startup)
  Guarantee:    On startup, the Storage Engine locates the snapshot file,
                validates its checksum (DAS-012 snapshot validation),
                and populates the DIR Runtime's unit store via write
                transactions (DDS-002:PC-6). The epoch counter and unit
                identity counter are restored from the snapshot. The
                per-file content hash map and deferred T2 recomputation
                queue are restored.

                After loading, the DIR Runtime is in Operational state
                with the unit store populated to the snapshotted epoch.
                The content hash map is available for reconciliation
                (DDS-007:PC-4). The deferred queue is available for the
                Update Engine.

                If no snapshot file exists (first launch), the Storage
                Engine signals the application lifecycle that a full
                rebuild is required. The DIR Runtime starts at epoch 0
                with an empty unit store.

                If the snapshot is corrupted (checksum mismatch,
                truncated file), the Storage Engine attempts to load
                the prior snapshot. If neither is valid, full rebuild
                is required.
  Preconditions: The DIR Runtime (DDS-002) has been created (state:
                 Loading — accepts write transactions for population).
  Failure mode: If the snapshot is corrupted and no prior snapshot is
                valid: the Storage Engine signals full rebuild. The DIR
                starts empty at epoch 0. All T0 and T1 content is
                rebuilt from source by the Producer Runtime. All T2
                content is lost and must be re-enriched on demand. This
                is the worst-case recovery path — functional but
                expensive for T2 (DAS-012 DA-5).

PC-3: Garbage Collection Execution
  Direction:    Offered
  Counterparty: DIR Runtime (DDS-002, fulfilling DDS-002:PC-7)
  Guarantee:    The Storage Engine evaluates which units are eligible
                for garbage collection based on the tier-informed
                retention policy:

                - T0 and T1 superseded units: eligible at the next
                  epoch after supersession (DAS-012 GC-R1).
                - T2 superseded units: eligible after a configurable
                  number of epochs since supersession (default: 100
                  epochs, DAS-012 GC-R2).
                - Invalidated T2 units: never collected while
                  invalidated — they serve graceful degradation
                  (DAS-012 GC-R3). Eligible only after supersession
                  (by fresh T2 recomputation) plus the T2 retention
                  period.
                - Units whose subject entity no longer exists: eligible
                  for immediate collection regardless of tier (DAS-012
                  GC-R4).

                For each eligible unit, the Storage Engine verifies GC
                safety: no Active or Invalidated unit's provenance.inputs
                references the candidate (DAS-012 I7). Units that pass
                the safety check are submitted as GC directives to the
                DIR Runtime via DDS-002:PC-2 (status transition to
                Garbage Collected).

                GC runs as a background operation — it does not execute
                during the synchronous pipeline and does not block
                epoch advancement (DAS-010 GC-3, DAS-012 GC-S1).
  Preconditions: The DIR Runtime is in Operational state. The Storage
                 Engine has access to the grounding dependency map (R3)
                 for safety verification.
  Failure mode: If the DIR Runtime rejects a GC directive
                (DDS-002:FM-2 — invalid transition, e.g., the unit's
                status changed between eligibility check and directive
                submission), the Storage Engine skips that unit. GC
                is best-effort per cycle — skipped units are
                re-evaluated in the next cycle. If GC cannot execute
                at all (DIR Runtime not operational), the unit store
                retains all units indefinitely (DDS-002:PC-7 failure
                mode) — this is safe but increases memory consumption.

PC-4: Grounding Dependency Map Access
  Direction:    Offered
  Counterparty: Update Engine (DDS-007, fulfilling DDS-007:PC-10)
  Guarantee:    Given a unit identifier, the Storage Engine returns the
                set of unit identifiers whose provenance.inputs field
                references it. This is the reverse grounding lookup
                required for invalidation cascade traversal (DAS-010
                IP-4). The lookup is O(degree) — proportional to the
                number of directly dependent units, not the total unit
                count.

                The map is maintained incrementally during operation:
                - When a new unit is admitted to the DIR (notified via
                  change batch from DDS-007), the Storage Engine adds
                  entries for each of the new unit's provenance.inputs.
                - When a unit is garbage-collected (after GC directive
                  execution), the Storage Engine removes entries for
                  that unit.
  Preconditions: The grounding dependency map has been constructed
                 (during startup, after snapshot load). During early
                 startup before construction completes, the map is
                 unavailable.
  Failure mode: If the map is not yet available (during startup before
                construction), a "not available" indicator is returned.
                The caller (DDS-007) falls back to DIR scan
                (DDS-007:FM-6). After the map is constructed, all
                subsequent lookups use the O(degree) path.

PC-5: Content Hash Map Access
  Direction:    Offered
  Counterparty: Update Engine (DDS-007, during reconciliation and
                change detection)
  Guarantee:    The Storage Engine provides the per-file content hash
                map: the mapping of tracked file paths to their content
                hashes as recorded in the snapshot. During operation,
                the Storage Engine updates the map when the Update Engine
                reports content hash changes (after successful change
                set processing). The map reflects the current committed
                epoch's source state.

                For reconciliation (DDS-007:PC-4), the Storage Engine
                provides the snapshot-era hash map so the Update Engine
                can compare against current on-disk hashes.

                For steady-state change detection (DDS-007:PC-1,
                DAS-010 CD-1), the Storage Engine provides the current
                hash for a given file path so the Update Engine can
                determine whether a file change event represents an
                actual content change.
  Preconditions: Snapshot has been loaded (or the map is empty on first
                 launch).
  Failure mode: None. The map is always available — it is an in-memory
                structure populated from the snapshot.

PC-6: Deferred Queue Persistence
  Direction:    Offered
  Counterparty: Update Engine (DDS-007, for deferred recomputation
                queue persistence)
  Guarantee:    The Storage Engine includes the deferred T2
                recomputation queue in every snapshot (R6). On startup,
                the queue is restored from the snapshot. On restoration,
                the queue is validated: any T2 unit with Invalidated
                status in the DIR but not in the queue is added; any
                queue entry referencing a non-existent or Active unit is
                removed (DAS-012 deferred queue semantics).

                During operation, the Update Engine owns the queue. The
                Storage Engine reads the queue contents at snapshot
                capture time.
  Preconditions: None for capture (the queue is read at snapshot time).
                 For restoration: snapshot has been loaded and the DIR
                 is populated.
  Failure mode: If the queue is lost (snapshot corruption affecting
                only the queue), the queue is reconstructed by scanning
                the DIR for T2 units with Invalidated status. No data
                is permanently lost — the queue is derivable from the
                DIR (DAS-012).
```

### Required Contracts

```
PC-7: DIR Read Access
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-3)
  Guarantee:    The Storage Engine can read the DIR's unit store contents
                at the committed epoch for snapshot capture (R1). Bulk
                read returns all units with their complete records (all
                10 fields, lifecycle status, supersession metadata,
                invalidation metadata). The read is consistent at the
                committed epoch — no partially-committed writes are
                visible.
  Preconditions: The DIR Runtime is in Operational or Quiescing state.
  Failure mode: If the DIR Runtime is in Loading state (during startup
                before population), reads are deferred until the DIR
                enters Operational state. If the DIR Runtime is
                Terminated, no reads are possible — but this occurs
                only after the Storage Engine has completed its final
                snapshot (destruction ordering per DDS-002).

PC-8: DIR Write Operations
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-6)
  Guarantee:    During snapshot loading (R2), the Storage Engine submits
                write transactions to populate the DIR Runtime's unit
                store. Each transaction admits units from the snapshot
                with their original identifiers, tiers, provenance,
                and lifecycle status. The DIR Runtime accepts these
                writes during its Loading state.
  Preconditions: The DIR Runtime is in Loading state (accepts write
                 transactions for population).
  Failure mode: If the DIR Runtime rejects a write transaction during
                loading (DDS-002:FM-1 — intake validation failure),
                the snapshot contains a unit that violates the current
                DIR contract. This indicates schema evolution or
                snapshot corruption. The Storage Engine logs the
                rejected units and continues loading the remaining
                units. If too many units are rejected (implementation-
                defined threshold), loading is abandoned and full
                rebuild is initiated.

PC-9: DIR Status Transitions
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-2)
  Guarantee:    The Storage Engine can submit garbage collection
                directives as status transitions: Superseded → Garbage
                Collected, Invalidated → Garbage Collected. The DIR
                Runtime executes the transitions and removes the
                collected units from the unit store.
  Preconditions: The target units have Superseded or Invalidated status.
                 GC safety is satisfied (R4).
  Failure mode: If the DIR Runtime rejects a transition
                (DDS-002:FM-2), the Storage Engine skips the unit and
                continues with remaining candidates.

PC-10: DIR Unit Resolution
  Direction:    Required
  Counterparty: DIR Runtime (DDS-002, via DDS-002:PC-5)
  Guarantee:    The Storage Engine can resolve unit identifiers to
                complete unit records. Used during grounding dependency
                map construction (to read provenance.inputs), during GC
                safety verification (to check whether a candidate is
                referenced by Active/Invalidated units), and during
                snapshot loading validation.
  Preconditions: The unit identifier was issued by the DIR Runtime.
  Failure mode: If the unit does not resolve (garbage collected or
                never issued), absent is returned. For GC safety
                checks, an absent referenced unit means the reference
                is stale — the candidate is still eligible for
                collection.

PC-11: Change Batch Notification
  Direction:    Required
  Counterparty: Update Engine (DDS-007, during synchronous and deferred
                pipeline execution)
  Guarantee:    The Update Engine notifies the Storage Engine of unit-
                level changes after each write transaction. The
                notification includes: units created (with their
                provenance.inputs for dependency map maintenance),
                units invalidated, units superseded. The Storage Engine
                uses these notifications to incrementally maintain the
                grounding dependency map (R3) and to update the per-file
                content hash map (R8).
  Preconditions: A write transaction has been committed to the DIR.
  Failure mode: If notifications are not received (Update Engine
                failure), the grounding dependency map becomes stale.
                The Storage Engine detects staleness by comparing the
                map's last-maintained epoch against the DIR's committed
                epoch. If they diverge, the map is rebuilt from the DIR.
```

---

## Lifecycle

### Creation

The Storage Engine is created during application startup, before the DIR Runtime (DDS-002) enters its Loading state. The Storage Engine is the first subsystem that touches persistent state — it locates the snapshot file and prepares for loading.

**Preconditions for creation:** The file system is accessible. The snapshot directory exists (or can be created).

**Startup sequence:** Storage Engine creation → snapshot location → snapshot validation → DIR Runtime creation (Loading state) → Storage Engine loads snapshot into DIR → DIR Runtime transitions to Operational → other subsystems start → Update Engine reconciliation (DDS-007:PC-4) → grounding dependency map construction → steady-state operation.

### Snapshot Loading

Immediately after the DIR Runtime enters Loading state, the Storage Engine loads the snapshot:

1. **Locate snapshot.** Find the canonical snapshot file. If absent, check for prior snapshot.
2. **Validate.** Verify the checksum. If invalid, attempt the prior snapshot.
3. **Deserialize.** Read the snapshot contents: units, epoch counter, unit identity counter, content hash map, deferred queue.
4. **Populate DIR.** Submit units to the DIR Runtime via write transactions (PC-8). Restore the epoch counter and identity counter.
5. **Restore metadata.** Make the content hash map (PC-5) and deferred queue (PC-6) available to the Update Engine.

If no valid snapshot exists, the Storage Engine signals first-launch or full-rebuild mode. The DIR starts at epoch 0 with an empty unit store.

### Grounding Dependency Map Construction

After the DIR is populated (snapshot loaded or empty), the Storage Engine constructs the grounding dependency map:

1. **Scan all units.** Read all units from the DIR via PC-7 (bulk read).
2. **Extract provenance.inputs.** For each unit V with provenance.inputs = {U₁, U₂, ...}, add entries mapping each Uᵢ → V.
3. **Signal availability.** After construction, PC-4 begins serving O(degree) lookups.

Construction is O(N) where N is total unit count. At alpha scale (~300,000 units), construction takes <500 ms. At the practical limit (~6,000,000 units), <10 seconds.

### Operation

The Storage Engine is operational after snapshot loading and grounding dependency map construction complete. It:
- Captures snapshots after epoch advancements (PC-1).
- Incrementally maintains the grounding dependency map (PC-4) via change batch notifications (PC-11).
- Runs garbage collection on schedule (PC-3).
- Serves content hash lookups (PC-5).
- Updates content hashes when the Update Engine reports processed changes.

### Quiescence

When the application is shutting down:

1. The Update Engine quiesces first (DDS-007 quiescence ordering) — no more change sets.
2. The Storage Engine captures the final snapshot (PC-1) from the DIR Runtime's Quiescing state.
3. The Storage Engine signals the DIR Runtime that the final snapshot is complete. The DIR Runtime transitions to Terminated.
4. The Storage Engine releases the grounding dependency map and content hash map.

**Quiescence ordering:** The Storage Engine quiesces after the Update Engine (to ensure no more writes) but before the DIR Runtime is destroyed (to ensure the final snapshot captures the complete state).

### Destruction

The Storage Engine is destroyed after the final snapshot is confirmed written. The grounding dependency map, content hash map, and any in-progress GC state are released. No persistent cleanup beyond the final snapshot is needed.

---

## State Model

The Storage Engine occupies one of five states:

```
Created → Loading → MapBuilding → Operational → Quiescing → Terminated
```

**Created.** The Storage Engine has been constructed. The snapshot file has been located and validated (or determined absent). The DIR Runtime has not yet been populated.

**Loading.** The snapshot is being deserialized and the DIR Runtime is being populated via write transactions. The grounding dependency map is not yet available. Snapshot capture and GC are not active.

**MapBuilding.** Snapshot loading is complete. The grounding dependency map is being constructed from the DIR. PC-4 returns "not available" during this state. Snapshot capture is available (PC-1). GC is not yet active (the map is needed for GC safety checks).

**Operational.** The grounding dependency map is constructed. All contracts are active: snapshot capture (PC-1), GC execution (PC-3), grounding dependency map access (PC-4), content hash access (PC-5), deferred queue persistence (PC-6). The Storage Engine serves requests and maintains state incrementally.

**Quiescing.** The application is shutting down. The final snapshot is being captured. GC is suspended. The grounding dependency map remains available for any final operations.

**Terminated.** The Storage Engine has been destroyed. No operations are valid.

**Transitions:**

| From | To | Trigger | Postcondition |
|------|----|---------|---------------|
| Created | Loading | DIR Runtime enters Loading state | Snapshot being deserialized |
| Loading | MapBuilding | DIR population complete; DIR Runtime Operational | Map construction begins |
| Loading | MapBuilding | No snapshot (first launch / full rebuild) | Empty map construction (trivial) |
| MapBuilding | Operational | Map construction complete | All contracts active |
| Operational | Quiescing | Shutdown signal | Final snapshot in progress |
| Quiescing | Terminated | Final snapshot confirmed | Resources deallocated |

**Invalid transitions:** Created → Operational (must load and build map first). Terminated → any state. Quiescing → Operational (shutdown is irreversible).

---

## Execution Model

### Snapshot Capture

Snapshot capture follows this sequence:

1. **Read DIR state.** Bulk read all units from the DIR Runtime at the committed epoch (PC-7). Read the epoch counter and unit identity counter.
2. **Read metadata.** Read the per-file content hash map. Read the deferred T2 recomputation queue from the Update Engine.
3. **Serialize.** Serialize all data into the snapshot format. Compute the checksum over the serialized contents.
4. **Write atomically.** Write the serialized data to a temporary file. Atomically rename the temporary file to the canonical snapshot path (DAS-012 snapshot atomicity). The prior snapshot is retained until the rename completes.
5. **Clean up.** Delete the prior snapshot file after confirming the new snapshot is valid.

**Snapshot timing.** Snapshot capture is triggered after each epoch advancement (both synchronous and deferred epochs). Capture may execute asynchronously — the snapshot captures the state at the moment of epoch advancement; the next change set can begin processing while the snapshot write is in progress, provided the prior epoch's state is fully serialized before overwriting begins.

**Snapshot skipping.** If a new epoch is advanced before the prior snapshot write completes, the in-progress snapshot write is allowed to finish. The new epoch's snapshot is deferred to the next epoch advancement. At most one epoch of state may be lost on crash in this scenario — the reconciliation mechanism (DDS-007:PC-4) reprocesses the missed changes from source.

### Garbage Collection

GC executes as a background operation, independent of the synchronous pipeline:

**GC scheduling.** GC is triggered after every Nth epoch advance (configurable, default: N=10, DAS-012 GC-S2). GC is also triggered when memory pressure exceeds a configurable threshold (DAS-012 GC-S3). GC never executes during the synchronous pipeline — it runs between change sets or concurrently with deferred pipeline operations.

**GC execution sequence:**

1. **Enumerate candidates.** Scan the DIR for units with Superseded or Invalidated status (via PC-7). Filter by retention policy:
   - T0/T1 Superseded: eligible if superseded at least 1 epoch ago (GC-R1).
   - T2 Superseded: eligible if superseded at least N epochs ago (GC-R2, default N=100).
   - Invalidated T2: not eligible (GC-R3) — retained for graceful degradation.
   - Units with non-existent subject entity: eligible immediately (GC-R4).

2. **Verify safety.** For each candidate, check the grounding dependency map (R3): is the candidate referenced by any Active or Invalidated unit's provenance.inputs? If yes, the candidate is not safe to collect — skip it.

3. **Issue directives.** Submit GC directives to the DIR Runtime via PC-9 (DDS-002:PC-2, transition to Garbage Collected). Directives are submitted in batches to amortize transaction overhead.

4. **Update dependency map.** For each collected unit, remove its entries from the grounding dependency map.

**GC and memory pressure.** Under memory pressure (DAS-012 GC-S3), GC may reduce retention periods: T2 superseded units may be collected sooner than the default 100 epochs. This is a safety valve — the reduction is bounded (minimum retention of 10 epochs) to prevent collecting T2 units that may still be useful for comparison or fallback.

### Grounding Dependency Map Maintenance

The grounding dependency map is built once on startup and maintained incrementally:

**Incremental maintenance.** When the Storage Engine receives a change batch notification (PC-11):
- For each newly created unit V with provenance.inputs = {U₁, U₂, ...}: add entries mapping each Uᵢ → V.
- For each garbage-collected unit V: remove all entries where V appears as a dependent. Also remove entries where V appears as a key (if V was in some unit's provenance.inputs, and that unit has been collected, the entry is already gone; if not, the key entry is stale but harmless — lookups will return V, which will resolve as absent via DDS-002:PC-5).

**Consistency check.** If the map's last-maintained epoch diverges from the DIR's committed epoch (detected when the Update Engine queries PC-4), the map is rebuilt from the DIR. This is a recovery mechanism — under normal operation, change batch notifications keep the map current.

### Concurrency Model

**Snapshot capture and pipeline independence.** Snapshot capture reads a committed epoch — it does not interfere with the synchronous pipeline. The snapshot serializes the DIR state at the moment of capture; subsequent writes do not affect the snapshot being written (the unit store is immutable per DDS-002 I-LC-5 — units are not mutated in place, so a snapshot read sees a consistent state).

**GC and pipeline independence.** GC runs between synchronous pipeline executions. GC directives are write transactions (DDS-002:PC-2) that are serialized with other writes by the DIR Runtime. GC does not execute during the synchronous pipeline (R4, DAS-010 GC-3).

**Map maintenance and pipeline coordination.** Map maintenance is driven by change batch notifications from the Update Engine. The notifications arrive after each write transaction within the pipeline. Map updates are applied sequentially — no concurrent map mutations.

---

## Memory and Ownership

### Owned State

**Grounding dependency map.** An in-memory reverse lookup structure. Owned exclusively by the Storage Engine. Built from DIR provenance records. Maintained incrementally via change batch notifications (PC-11). Not persisted — rebuilt on every startup (DAS-012).

Memory footprint: proportional to the total number of provenance.inputs edges in the DIR. Each edge is a (key unit ID → dependent unit ID) pair. At alpha scale (~300,000 units, average ~2 provenance inputs per unit): ~600,000 entries × ~16 bytes ≈ 10 MB. At the practical limit (~6,000,000 units): ~200 MB.

**Per-file content hash map.** Maps tracked file paths to content hashes. Owned exclusively by the Storage Engine. Persisted in the snapshot. Updated when the Update Engine reports content changes.

Memory footprint: one entry per tracked file. At alpha scale (~1,000 files): ~1,000 entries × ~200 bytes (path + hash) ≈ 200 KB. At the practical limit (~10,000 files): ~2 MB.

**Snapshot serialization buffer.** Temporary buffer used during snapshot capture. Sized to the snapshot file size (~60 MB at alpha, ~1.2 GB at practical limit). Allocated during capture, released after write completes.

### Borrowed State

**DIR unit store (read).** The Storage Engine reads the unit store through DDS-002 contracts (PC-7, PC-10). It does not own or modify the unit store directly.

**Deferred recomputation queue (read at snapshot time).** Owned by DDS-007 during operation. The Storage Engine reads the queue contents at snapshot capture time and writes them into the snapshot. On restore, the Storage Engine provides the queue to DDS-007.

### Memory Bounds

**Total Storage Engine memory (excluding snapshot buffer):** ~10 MB at alpha scale, ~200 MB at practical limit. The grounding dependency map dominates.

**Snapshot buffer:** ~60 MB at alpha, ~1.2 GB at practical limit. Temporary — allocated only during capture.

**Combined:** The Storage Engine's memory footprint is significant at the practical limit (~1.4 GB including snapshot buffer). This is within the scale envelope defined by DAS-012 (total system memory budget: ~1.8 GB for DIR + indexes + supporting structures on a 16 GB system).

---

## Failure Handling

```
FM-1: Snapshot Write Failure
  Trigger:     The snapshot write to disk fails (disk full, I/O error,
               permission denied, process interrupted during write).
  Detection:   File system error during temporary file write or atomic
               rename.
  Response:    The prior snapshot remains valid on disk (the atomic
               write pattern ensures the canonical path always contains
               a complete snapshot or the prior complete snapshot). The
               Storage Engine logs the failure and records it in
               observability. The DIR continues operating normally — no
               runtime correctness is affected.
  Caller observes: The epoch advancement and runtime operation proceed
               unaffected. The next epoch advancement triggers another
               snapshot attempt.
  Recovery:    Automatic on the next successful snapshot write. If disk
               issues persist, the recovery window (gap between last
               valid snapshot and crash) grows. The application should
               surface persistent snapshot failures to the user.

FM-2: Snapshot Load Failure (Corruption)
  Trigger:     The snapshot file fails checksum validation during
               startup loading.
  Detection:   Checksum mismatch between computed and stored checksum.
  Response:    The Storage Engine attempts to load the prior snapshot
               file. If the prior snapshot is valid, loading proceeds
               with the prior epoch's state (at most one epoch of
               state is lost — reprocessed via reconciliation). If
               neither snapshot is valid, the Storage Engine signals
               full rebuild.
  Caller observes: The application starts with either: (a) a slightly
               older snapshot state, reconciled to current source, or
               (b) a full rebuild from source (T0/T1 immediate, T2
               on demand).
  Recovery:    For case (a): reconciliation (DDS-007:PC-4) bridges the
               gap. For case (b): full rebuild via the Producer Runtime
               (DDS-001:PC-5) restores T0/T1 content. T2 content is
               rebuilt on demand (DDS-007:PC-2). The system is fully
               functional after T0/T1 rebuild; T2 is eventually
               consistent.

FM-3: Snapshot Load Failure (Schema Evolution)
  Trigger:     The snapshot contains units that fail intake validation
               under the current DIR contract (DDS-002:FM-1). This
               occurs when the application is upgraded and the DIR
               contract has changed (new predicates, tightened
               validation).
  Detection:   Write transaction rejection during snapshot population
               (PC-8).
  Response:    The Storage Engine logs the rejected units and continues
               loading the remaining units. If the rejection count
               exceeds an implementation-defined threshold (indicating
               widespread incompatibility rather than isolated stale
               units), loading is abandoned and full rebuild is
               initiated.
  Caller observes: The application starts with either a partially
               loaded DIR (missing the rejected units) followed by
               reconciliation, or a full rebuild.
  Recovery:    Reconciliation or full rebuild restores the missing
               content under the current contract. The stale snapshot
               is overwritten by the next snapshot capture.

FM-4: GC Safety Violation Detected
  Trigger:     During GC execution, the safety check discovers that a
               candidate unit is referenced by an Active or Invalidated
               unit's provenance.inputs — despite passing the initial
               eligibility filter.
  Detection:   Grounding dependency map lookup during safety
               verification.
  Response:    The candidate is skipped. This is not an error — it
               indicates that the candidate's status (Superseded)
               satisfies the eligibility policy but its grounding
               chain position prevents safe collection. The candidate
               will be re-evaluated in the next GC cycle. It becomes
               collectible when all referencing units are themselves
               superseded or collected.
  Caller observes: No external effect. GC proceeds with remaining
               candidates.
  Recovery:    None needed. The candidate is naturally freed when its
               dependents are superseded.

FM-5: Grounding Dependency Map Inconsistency
  Trigger:     A map lookup returns a result that is inconsistent with
               the DIR's actual provenance records (e.g., the map
               claims unit V depends on U, but V.provenance.inputs
               does not contain U, or vice versa).
  Detection:   Detected during GC safety verification (discrepancy
               between map and DIR), or during map maintenance
               (unexpected absent unit during incremental update).
  Response:    The Storage Engine initiates a full map rebuild from
               the DIR's current provenance records. During rebuild,
               the map is temporarily unavailable (state transitions
               to a rebuild mode). The Update Engine falls back to
               DIR scan (DDS-007:FM-6) during rebuild.
  Caller observes: Temporarily degraded cascade traversal performance
               (O(N) instead of O(degree)) during map rebuild. Full
               performance restored after rebuild completes.
  Recovery:    Automatic — rebuild from DIR is always correct. The
               rebuilt map replaces the inconsistent map atomically.

FM-6: Disk Space Exhaustion During Operation
  Trigger:     The file system reports insufficient space during
               snapshot capture or GC cannot free enough memory.
  Detection:   I/O error during snapshot write, or memory pressure
               exceeding the scale envelope after maximum GC.
  Response:    For snapshot: FM-1 applies. For memory: GC enters
               aggressive mode (minimum retention periods) per
               DAS-012 GC-S3. If aggressive GC is insufficient, the
               system operates within available memory — new writes
               that would exceed available memory are rejected
               (DDS-002:FM-5). The system degrades to T0/T1-only
               operation if T2 units are collected aggressively.
  Caller observes: Snapshot failures and/or DIR write rejections.
               Observability metrics flag the resource constraint.
  Recovery:    Disk space: clear disk space or increase available
               storage. Memory: reduce the tracked scope, increase
               available memory, or evolve the storage topology
               (DAS-012 Q1).
```

---

## Performance Requirements

### Architectural Requirements

**PR-1: Snapshot capture does not block the synchronous pipeline.** Snapshot serialization and disk write occur after epoch advancement. The next change set may begin processing while the snapshot write is in progress. (DAS-010 GC-3 principle: background operations do not block updates.)

**PR-2: GC does not block the synchronous pipeline.** GC runs between change sets or concurrently with deferred pipeline operations. GC directives are serialized with other DIR writes but do not delay the synchronous pipeline. (DAS-010 GC-3.)

**PR-3: Grounding dependency map lookup is O(degree).** Where degree is the number of directly dependent units for a given unit. The lookup must not scan the entire DIR. (DAS-012, DAS-010 IP-4.)

**PR-4: GC safety verification is O(degree) per candidate.** Checking whether a candidate is referenced by Active/Invalidated units uses the grounding dependency map. Must not scan the entire DIR per candidate. (DAS-012 I7.)

### Engineering Targets

**ET-1: Snapshot capture latency.** Target: <50 ms for serialization + write at alpha scale (~60 MB). At practical limit (~1.2 GB): <500 ms. Includes checksum computation.

**ET-2: Snapshot loading latency.** Target: <100 ms at alpha scale. At practical limit: <2 seconds. Includes checksum validation, deserialization, and DIR population.

**ET-3: Grounding dependency map construction.** Target: <500 ms at alpha scale (~300,000 units). At practical limit: <10 seconds.

**ET-4: GC cycle duration.** Target: <50 ms at alpha scale (scanning eligibility, verifying safety, issuing directives). GC should complete within the inter-change-set window without user-perceptible impact.

**ET-5: Incremental map maintenance per change batch.** Target: <1 ms for a typical single-file change batch (~20 new units, ~20 superseded units).

---

## Observability

**OB-1: Snapshot metrics.** For each snapshot capture: serialization duration, write duration, snapshot file size, epoch captured, success/failure status. For loading: load duration, checksum validation duration, units loaded, epoch restored.

**OB-2: GC metrics.** For each GC cycle: candidates evaluated, candidates collected, candidates skipped (safety check), candidates skipped (retention not met), collection duration, memory freed estimate. Per-tier breakdown of collected units.

**OB-3: Grounding dependency map metrics.** Map entry count, construction duration, incremental maintenance operations per change batch, rebuild events (count and cause), lookup latency (sampled).

**OB-4: Content hash map metrics.** Tracked file count, hash update count per change set.

**OB-5: Crash recovery metrics.** On startup: snapshot found/absent, snapshot valid/corrupted, prior snapshot used, full rebuild triggered, reconciliation file count.

**OB-6: Memory metrics.** Grounding dependency map memory footprint, content hash map memory footprint, snapshot buffer allocation events.

---

## Testing Requirements

### Contract Tests

- PC-1 (Snapshot Capture): After epoch advancement, the Storage Engine produces a valid snapshot file. The snapshot contains all Active and Invalidated units, the correct epoch counter, the content hash map, and the deferred queue. The snapshot file is atomically written (interrupt during write leaves prior snapshot intact).
- PC-2 (Snapshot Loading): A snapshot produced by PC-1 is loadable — the DIR is populated with the same units, epoch, and identity counter. Checksum validation detects corruption (flip a byte in the snapshot, confirm rejection).
- PC-3 (GC Execution): T0/T1 superseded units are collected after 1 epoch. T2 superseded units are retained for the configured retention period. Invalidated T2 units are never collected. Units with non-existent subjects are collected immediately. Units referenced by Active units are never collected (GC safety).
- PC-4 (Grounding Dependency Map): A lookup for a unit U returns exactly the set of units whose provenance.inputs includes U. After a new unit V with provenance.inputs = {U} is admitted, a lookup for U returns V. After V is garbage-collected, the lookup for U no longer returns V.
- PC-5 (Content Hash Map): After a file change is processed, the content hash for that file is updated. On restart, the restored hash map matches the prior epoch's state.
- PC-6 (Deferred Queue Persistence): The queue survives a restart cycle — invalidated T2 units present in the queue before shutdown are present after restart.

### State Model Tests

- Created → Loading → MapBuilding → Operational transitions occur during startup with a valid snapshot.
- Created → Loading → MapBuilding → Operational transitions occur during first launch (no snapshot, empty map construction).
- Operational → Quiescing → Terminated transitions occur during shutdown, with final snapshot captured.
- PC-4 returns "not available" during Loading and MapBuilding states.

### Failure Mode Tests

- FM-1: Simulate disk full during snapshot write. Confirm prior snapshot remains valid and DIR operation is unaffected.
- FM-2: Corrupt the primary snapshot file. Confirm the Storage Engine falls back to the prior snapshot. Corrupt both snapshots. Confirm full rebuild is initiated.
- FM-3: Create a snapshot with units that violate the current intake validation (e.g., missing a required field). Confirm partial loading with logged rejections, or full rebuild if threshold exceeded.
- FM-4: Create a unit eligible for GC by retention policy but referenced by an Active unit's provenance.inputs. Confirm the unit is skipped, not collected.
- FM-5: Introduce a deliberate map inconsistency. Confirm the Storage Engine detects it and triggers a full map rebuild.

### Invariant Tests

- **RI-1 (Snapshot Single-Epoch Integrity):** Every snapshot contains data from exactly one committed DIR epoch. After capture, verify that the snapshot's epoch counter, all unit lifecycle timestamps, content hash map state, and deferred queue state correspond to the same committed epoch. No snapshot may contain units or metadata from different committed epochs.
- **DAS-012 I1 (Snapshot Epoch Correspondence):** The snapshot on disk represents a consistent DIR state. After loading, all T0 and T1 units are Active (not Invalidated).
- **DAS-012 I2 (Snapshot Atomicity):** Interrupting the process during a snapshot write leaves a valid snapshot on disk (either the prior or the current, never a partial).
- **DAS-012 I5 (Single Snapshot Persistence):** At no point do more than two snapshot files exist on disk.
- **DAS-012 I6 (Grounding Dependency Map Consistency):** For every unit V in the DIR with provenance.inputs = {U₁, U₂, ...}, each Uᵢ has an entry in the map pointing to V. For every entry in the map, the corresponding provenance relationship exists.
- **DAS-012 I7 (GC Safety):** No collected unit is referenced by any Active or Invalidated unit's provenance.inputs or grounding chain.
- **DAS-012 I8 (Memory Boundedness):** After sustained operation (many change sets and GC cycles), memory usage stabilizes — it does not grow unboundedly with epoch count.

### Integration Tests

- End-to-end persistence: File change → synchronous pipeline → epoch advancement → snapshot capture → process restart → snapshot load → reconciliation → consumer query returns the correct content.
- GC integration: Create units, supersede them, advance epochs past retention → GC collects superseded units → memory freed → snapshot reflects the smaller unit set.
- Grounding dependency map integration: File change → cascade propagation → Update Engine queries PC-4 → receives correct dependents → cascade proceeds correctly.
- Crash recovery: Kill process during synchronous pipeline → restart → load prior snapshot → reconcile changed files → DIR is consistent.
- Full rebuild: Delete snapshot files → start process → full rebuild from source → T0/T1 populated → snapshot captured → restart → snapshot loads normally.

---

## Future Evolution

**Disk-backed storage.** At codebases exceeding ~10,000 files, the in-memory DIR and grounding dependency map may exceed reasonable memory budgets. The natural evolution path (DAS-012 Q1): persist selected indexes to avoid rebuild cost, then move the DIR to a disk-backed store with in-memory caching. The Storage Engine's contracts (PC-1 through PC-11) are topology-agnostic — they define logical operations, not physical locations. A disk-backed evolution would change the Storage Engine's internals without affecting its contract surface.

**Incremental snapshots.** At the practical limit (~1.2 GB), full snapshot writes may exceed latency targets. Incremental snapshots (writing only changed units since the last full snapshot) would reduce I/O. This adds merge-on-read complexity during loading and periodic compaction. The snapshot capture contract (PC-1) is compatible with incremental snapshots — the guarantee is a complete, consistent snapshot, regardless of how it is physically composed.

**Adaptive snapshot frequency.** For workloads with rapid saves (>5 saves/second), per-epoch snapshots may generate excessive I/O. An adaptive strategy (snapshot every N epochs or every T seconds, whichever comes first) would reduce I/O while bounding the recovery window. PC-1's trigger (after epoch advancement) could be gated by the adaptive strategy without changing the contract.

**Snapshot export/import.** A snapshot contains the complete DIR state at a point in time. Exporting a snapshot for offline analysis or importing a known-good snapshot for debugging would be useful during development. This is a tooling concern, not an architectural one — no existing contracts would be affected. Export/import would be additional offered contracts beyond PC-1 through PC-6. Evaluate debugging needs during alpha; if snapshot inspection becomes a common debugging workflow, add export/import support.

---

## Revision History

```
0.2 — 2026-06-28 — Principal Engineer — CTO review revisions.
    (1) Resolved Q1: grounding dependency map remains exclusively owned by
    the Storage Engine — it is a write-side structure for invalidation
    cascade traversal, not a consumer retrieval index. Not an Index Runtime
    index family. Updated R3 boundary, terminology definition. (2) Added
    runtime invariant RI-1 (Snapshot Single-Epoch Integrity): every snapshot
    represents exactly one committed DIR epoch, never data spanning multiple
    epochs. Updated PC-1 guarantee and invariant tests. (3) Moved Q2
    (snapshot export/import) from Open Questions to Future Evolution as a
    potential capability. Open Questions section removed (no remaining
    questions).

0.1 — 2026-06-28 — Principal Engineer — Initial specification of the Storage
    Engine Runtime. Realizes DAS-012 (Storage Realization) as the subsystem
    owning snapshot persistence, grounding dependency map, garbage collection,
    crash recovery, and content hash tracking. Depends on DDS-002 (DIR
    Runtime Model) and DDS-007 (Update Engine Runtime). Eleven offered and
    required contracts (PC-1 through PC-11). Eight responsibilities.
    Five-state model (Created, Loading, MapBuilding, Operational, Quiescing).
    Six failure modes. Six observability concerns. Two open questions.
    Fulfills DDS-002:PC-7 (GC Directives) and DDS-002:PC-8 (Snapshot
    Capture). Fulfills DDS-007:PC-10 (Grounding Chain Traversal).
```

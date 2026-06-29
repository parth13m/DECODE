# IAG-002 — Technology Decisions

| Field | Value |
|-------|-------|
| **Document** | IAG-002 |
| **Title** | Technology Decisions |
| **Status** | Draft |
| **Version** | 0.2 |
| **Created** | 2026-06-28 |
| **Depends On** | IAG-001 (Module Architecture), DDS-000 through DDS-009 (all frozen) |
| **Consumed By** | IAG-003 (Runtime Architecture), IAG-004 (Implementation Sequence) |

---

## Preamble: IAG Layer Definition

### Purpose of the IAG Layer

The Implementation Architecture Guide (IAG) layer translates frozen Design Specifications (DDS) into codebase structure. It occupies the space between behavioral specification and source code.

The DDS layer defines **what** each subsystem must do — contracts, invariants, responsibilities, failure modes. The IAG layer defines **how the codebase is organized** to realize those specifications. Implementation defines **the source code** within that organization.

### What Belongs in IAG

An IAG statement must satisfy this test:

> **An engineer could not correctly implement the frozen DDS without this decision.**

IAG-002 specifically records technology selection decisions: which frameworks, libraries, and platform APIs fulfill DDS responsibilities. Each decision includes the selection, rationale, DDS traceability, imposed constraints, and reconsideration conditions.

### What Must Never Appear in IAG

**Belongs in DDS (behavioral specification):**
Subsystem responsibilities, contracts, invariants, state models, failure taxonomies, observability requirements, performance bounds. IAG-002 may reference a DDS requirement that a technology fulfills, but must never restate the requirement's semantics.

**Belongs in IAG-003 (runtime architecture):**
How a selected technology is applied to specific subsystem boundaries — actor placement, async/await boundary decisions, data flow patterns. IAG-002 selects "Swift Concurrency"; IAG-003 specifies which subsystems are actors.

**Belongs in implementation (source code):**
API usage patterns, method signatures, configuration code, schema definitions, specific data structures. IAG-002 selects "Codable + atomic file I/O for snapshots"; implementation defines the snapshot schema.

### Relationship to DAS, DDS, and Implementation

```
DAS (frozen, permanent)     — defines architectural principles and invariants
  ↓
DDS (frozen, permanent)     — specifies subsystem contracts and behavior
  ↓
IAG (transient, consumed)   — maps subsystems to code modules and technologies
  ↓
Implementation (permanent)  — realizes DDS contracts using IAG structure and technologies
```

---

## 1. Technology Selection Principles

Every technology decision in this document is governed by five principles:

| # | Principle | Statement |
|---|-----------|-----------|
| **TP-1** | DDS Traceability | Every technology selection must trace to at least one DDS responsibility it enables. A technology without a DDS justification does not belong in the understanding pipeline. |
| **TP-2** | Platform Alignment | Prefer Apple-provided frameworks and Swift standard library over third-party alternatives. Third-party dependencies are justified only when the platform provides no viable equivalent. |
| **TP-3** | Existing Stack Continuity | When the existing Decode application already uses a technology for a comparable purpose, the understanding pipeline adopts the same technology unless a DDS requirement disqualifies it. This avoids redundant dependencies and ensures team familiarity. |
| **TP-4** | Minimal Dependency Surface | Each third-party dependency adds upgrade risk, build complexity, and a trust boundary. The smallest dependency set that fulfills DDS requirements is preferred. |
| **TP-5** | Reversibility | Every technology decision must have a defined migration path. Technologies that would be prohibitively expensive to replace are selected only when no reversible alternative exists. |

---

## 2. Selection Criteria

For each technology decision, the following criteria are evaluated:

| Criterion | Question |
|-----------|----------|
| **DDS Coverage** | Which DDS responsibilities does this technology enable? |
| **Platform Availability** | Is there a platform-provided equivalent? |
| **Existing Usage** | Is this technology already used in the Decode codebase? |
| **Swift 6 Compatibility** | Does it compile under Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`)? |
| **Sendable Conformance** | Are its public types `Sendable`-compatible, or do they require `@unchecked Sendable` wrappers? |
| **Dependency Weight** | How many transitive dependencies does it introduce? |
| **Replacement Cost** | How many modules would be affected if this technology were replaced? |
| **Maturity** | Is it stable, actively maintained, and unlikely to introduce breaking changes? |

---

## 3. Technology Decision Lifetime Categories

Every technology decision is classified into one of three lifetime categories:

| Category | Definition | Characteristics |
|----------|-----------|-----------------|
| **Foundational** | The technology is structurally embedded in the project. Replacing it would require rewriting the majority of the codebase or is practically impossible without changing the product's nature. | No migration path exists in practice. The decision is permanent for the lifetime of the project. Reconsideration means rebuilding, not replacing. |
| **Replaceable** | The technology fulfills a specific DDS responsibility and is isolated behind a protocol or module boundary. Replacing it affects one or a small number of modules. A defined migration path exists. | The decision has a finite lifetime. When reconsideration conditions are met, the technology can be swapped by implementing the same protocols with a different library or framework. |
| **Commodity** | The technology is a standard platform capability with no viable alternative. It is selected because it is the only option, not because it was chosen over competitors. | The decision is permanent not by design but by absence of alternatives. No active evaluation is needed. If the platform introduces a successor, it becomes the new commodity default. |

### Lifetime Classification

| Decision | Technology | Lifetime | Justification |
|----------|-----------|----------|---------------|
| TD-1 | Swift 6.0 | **Foundational** | The platform language. Every line of code is Swift. Replacement means rewriting the product. |
| TD-2 | Swift Concurrency | **Foundational** | The concurrency model pervades every module boundary, every protocol signature, and every isolation decision. Replacing it would require rewriting all cross-module interfaces and all isolation logic. |
| TD-3 | SwiftSyntax | **Replaceable** | Isolated to `ProducerRuntime` (M2) behind a parser protocol. Can be replaced by any library that produces equivalent parse results. |
| TD-4 | SwiftTreeSitter | **Replaceable** | Isolated to `ProducerRuntime` (M2) behind a parser protocol. Can be replaced by any multi-language parser with equivalent language coverage. |
| TD-5 | URLSession | **Commodity** | The platform-native HTTP client. No viable alternative exists for macOS. If Apple introduces a successor, it becomes the new commodity default. |
| TD-6 | DispatchSource | **Commodity** | The platform-native file monitoring mechanism. No viable alternative exists. If Apple provides an async-native replacement, it becomes the new commodity default. |
| TD-7 | Codable + atomic I/O | **Replaceable** | The serialization contract (Codable protocol) is isolated to `DIRCore` types and `StorageEngine` logic. The encoder can be swapped independently. The full Codable contract can be replaced with a custom serialization protocol if performance requires it. |
| TD-8 | CryptoKit SHA-256 | **Commodity** | The platform-native hash function. No viable alternative exists for content hashing with collision resistance. The hash algorithm could be changed if DDS-007 I6 requirements evolve, but CryptoKit remains the framework. |
| TD-9 | XcodeGen | **Replaceable** | Build system tooling. Can be replaced by SPM or manual Xcode project management. The module architecture (IAG-001) is independent of the build system tool. |
| TD-10 | XCTest | **Replaceable** | Testing framework. Can be incrementally replaced by Swift Testing. Both frameworks coexist within a target. |
| TD-11 | os.Logger | **Commodity** | The platform-native structured logging framework. No viable alternative exists for macOS client-side diagnostics. |

---

## 4. Technology Decision Ownership

Every technology decision has an engineering owner: the module or platform concern responsible for evaluating future changes to that decision. Ownership does not mean exclusive usage — it means responsibility for monitoring reconsideration conditions and initiating reassessment.

| Decision | Technology | Engineering Owner | Rationale |
|----------|-----------|-------------------|-----------|
| TD-1 | Swift 6.0 | Platform (project-wide) | Language version affects all modules. Evaluation is triggered by Xcode/Swift releases. |
| TD-2 | Swift Concurrency | Platform (project-wide) | Concurrency model affects all module boundaries. Evaluation is a project-level decision. |
| TD-3 | SwiftSyntax | `ProducerRuntime` (M2) | Sole consumer. M2 engineers monitor SwiftSyntax releases, Swift compiler changes, and parsing capability gaps. |
| TD-4 | SwiftTreeSitter | `ProducerRuntime` (M2) | Sole consumer. M2 engineers monitor grammar availability, binding stability, and language coverage requirements. |
| TD-5 | URLSession | Platform (project-wide) | Platform networking. No active evaluation needed. Commodity. |
| TD-6 | DispatchSource | `UpdateEngine` (M7) | Sole consumer in the understanding pipeline. M7 engineers monitor for async-native file monitoring APIs. |
| TD-7 | Codable + atomic I/O | `StorageEngine` (M8) | Sole consumer of serialization logic. M8 engineers monitor snapshot performance and evaluate encoder alternatives. `DIRCore` (M1) co-owns Codable conformance declarations on types. |
| TD-8 | CryptoKit SHA-256 | `UpdateEngine` (M7) / `StorageEngine` (M8) | Shared between change detection (M7) and content hash persistence (M8). Joint ownership — either module may trigger reassessment if hashing becomes a bottleneck. |
| TD-9 | XcodeGen | Platform (project-wide) | Build system tooling is project-level. Evaluation triggered by build system limitations or team workflow changes. |
| TD-10 | XCTest | Platform (project-wide) | Testing framework is project-level. Evaluation triggered by team adoption of Swift Testing. |
| TD-11 | os.Logger | Platform (project-wide) | Observability framework is project-level. Evaluation triggered by production observability requirements. |

---

## 5. Technology Decision Records

### TD-1: Swift 6.0 — Platform Language

| Field | Value |
|-------|-------|
| **Technology** | Swift 6.0 |
| **Category** | Language |
| **Source** | Apple platform SDK |
| **Version** | 6.0 (Xcode 16.2) |
| **Existing Usage** | Yes — entire Decode codebase |

**Why this technology.** Swift is the native language for macOS development. The existing Decode application is written entirely in Swift 6.0 with strict concurrency checking enabled (`SWIFT_STRICT_CONCURRENCY = complete`). There is no viable alternative for a native macOS application.

**Which DDS responsibilities it enables.** All. Every DDS subsystem is implemented in Swift.

**What constraints it imposes.**
- All types crossing concurrency boundaries must be `Sendable` or explicitly marked `@unchecked Sendable` with documented justification.
- Strict concurrency checking catches data races at compile time. All mutable shared state must use an isolation mechanism (actor, serial queue, or lock).
- macOS 15.0 minimum deployment target — required for Swift 6.0 runtime and modern SwiftUI APIs.

**When to reconsider.** Not applicable. Swift is a non-negotiable platform requirement.

---

### TD-2: Swift Concurrency — Concurrency Framework

| Field | Value |
|-------|-------|
| **Technology** | Swift Concurrency (actors, async/await, structured concurrency, AsyncSequence) |
| **Category** | Concurrency framework |
| **Source** | Swift standard library |
| **Version** | Swift 6.0 runtime |
| **Existing Usage** | Yes — primary concurrency model throughout Decode |

**Why this technology.** Swift Concurrency is the platform-native concurrency framework. The existing Decode codebase uses async/await, Task, and AsyncStream extensively (34+ AsyncStream occurrences across 21 files). No Combine usage exists. GCD is used only where platform APIs require it (DispatchSource for file watching). Swift Concurrency provides compile-time data race safety under strict concurrency, which directly supports DDS isolation requirements.

**Which DDS responsibilities it enables.**
- DDS-002: Single-writer unit store isolation (actor-based or serial-queue-based; IAG-003 decides which)
- DDS-002: Epoch-consistent read access — concurrent readers must not observe partially-committed state
- DDS-007: Sequential change set processing (DDS-007 I8) — serialized execution
- DDS-007: Pipeline coordination — structured concurrency for ordered execution within a cycle
- DDS-001: Failure isolation — Task cancellation for producer timeout enforcement (DDS-001:FM-2)
- DDS-003: Pass cancellation — cooperative cancellation via Task.isCancelled (DDS-003:PC-4)
- DDS-009: Consumer invocation — async request/response pattern
- All modules: Cross-module protocol calls are async, enabling non-blocking coordination

**What constraints it imposes.**
- All cross-module protocol methods must be `async` (or explicitly synchronous with documented justification).
- All types passed across module boundaries must be `Sendable`.
- Actor isolation requires careful design of the public API surface — methods on an actor are implicitly isolated and require `await` from outside.
- Structured concurrency (TaskGroup) must be used for parallelizable work within a pipeline stage; unstructured Task creation is reserved for fire-and-forget operations and lifecycle management.
- `@MainActor` is used only in the Presentation layer and the composition root. No understanding pipeline module uses `@MainActor`.

**When to reconsider.** Not applicable. Swift Concurrency is the platform-native model. GCD is legacy for new code. Combine is unused in the codebase and offers no advantage over AsyncSequence for the understanding pipeline's needs.

**Boundary with IAG-003.** IAG-002 selects Swift Concurrency as the concurrency framework. IAG-003 specifies how it is applied: which subsystems are actors, where async boundaries fall, how cancellation propagates, and how data flows between subsystems.

---

### TD-3: SwiftSyntax — Swift AST Parsing

| Field | Value |
|-------|-------|
| **Technology** | SwiftSyntax (SwiftParser + SyntaxVisitor) |
| **Category** | AST parsing library |
| **Source** | Third-party (Apple-maintained, github.com/swiftlang/swift-syntax) |
| **Version** | 600.0.1 (exact, pinned) |
| **Existing Usage** | Yes — `SwiftSyntaxParser.swift` in Infrastructure/AST |

**Why this technology.** SwiftSyntax is the official Swift AST parsing library, maintained by the Swift team. It provides type-safe AST traversal via the Visitor pattern. The existing Decode codebase uses it for entity extraction, import parsing, and relationship detection in Swift files. No alternative provides equivalent Swift parsing fidelity.

**Which DDS responsibilities it enables.**
- DDS-001 R1, R2: Producer registration and DAG construction — Swift frontends use SwiftSyntax to extract entities, imports, and relationships from Swift source files
- DDS-001 R3: Producer execution — Swift frontends produce DIR units via SwiftSyntax-derived parse results
- DDS-003 R1: Input assembly — pass input contracts reference entities extracted by SwiftSyntax frontends

**What constraints it imposes.**
- **Version coupling.** SwiftSyntax major versions are tied to Swift compiler versions. SwiftSyntax 600.x corresponds to Swift 6.0. Upgrading Swift requires upgrading SwiftSyntax.
- **Compilation time.** SwiftSyntax is a large dependency (~50+ source files). Initial compilation is slow; incremental builds are acceptable.
- **Thread safety.** SwiftSyntax types are value types and thread-safe. No isolation concerns.
- **Module scope.** Used only within `ProducerRuntime` (M2). No other understanding pipeline module imports SwiftSyntax.

**When to reconsider.** Only if Swift introduces a built-in parsing API that supersedes SwiftSyntax, or if a DDS requirement needs parsing capabilities that SwiftSyntax cannot provide (e.g., type resolution — see CLAUDE.md "Swift conformance ambiguity" known limitation).

---

### TD-4: SwiftTreeSitter + Language Grammars — Multi-Language AST Parsing

| Field | Value |
|-------|-------|
| **Technology** | SwiftTreeSitter (Swift bindings for tree-sitter) + 9 language grammar packages |
| **Category** | AST parsing library |
| **Source** | Third-party (ChimeHQ/SwiftTreeSitter + tree-sitter organization) |
| **Version** | SwiftTreeSitter ≥0.10.0 (resolved to 0.25.0); grammar packages pinned to exact versions |
| **Existing Usage** | Yes — `TreeSitterParser.swift` and `QueryLoader.swift` in Infrastructure/AST |

**Why this technology.** Tree-sitter provides incremental, error-tolerant parsing for languages other than Swift. Decode supports 9 additional languages (Python, JavaScript, TypeScript, HTML, CSS, Java, C#, C, C++). No viable alternative provides equivalent multi-language parsing with a unified API. Each language grammar is a separate SPM package with its own versioning.

**Which DDS responsibilities it enables.**
- DDS-001 R1, R2: Producer registration and DAG construction — non-Swift frontends use tree-sitter to extract entities, imports, and relationships
- DDS-001 R3: Producer execution — non-Swift frontends produce DIR units via tree-sitter parse results
- DDS-003 R4: Execution strategy — deterministic passes may use tree-sitter for structural analysis
- DDS-003 R6: Changed output detection — tree-sitter parses enable structural comparison

**What constraints it imposes.**
- **Dependency count.** 11 SPM packages (SwiftTreeSitter + tree-sitter core + 9 grammars). This is the largest dependency cluster in the project.
- **C interop.** Tree-sitter core is a C library. Grammar packages contain C source compiled as SPM targets. Build times are acceptable but toolchain changes can cause transient build issues.
- **Grammar versioning.** Each grammar is pinned to an exact version. Grammar updates must be tested individually for parse correctness.
- **Query files.** Tree-sitter queries (`.scm` files) are bundled as build resources. Adding a new language requires both a grammar package and query files.
- **SQL grammar excluded.** Upstream SPM package issue prevents inclusion (see CLAUDE.md known limitations).
- **Module scope.** Used only within `ProducerRuntime` (M2). No other understanding pipeline module imports tree-sitter packages.

**When to reconsider.** Only if: (a) Apple provides a built-in multi-language parsing framework, (b) tree-sitter's Swift bindings become unmaintained, or (c) a new language support requirement cannot be met by tree-sitter grammars.

---

### TD-5: URLSession — HTTP Networking

| Field | Value |
|-------|-------|
| **Technology** | URLSession (Foundation) |
| **Category** | Networking |
| **Source** | Apple platform SDK |
| **Version** | macOS 15.0 SDK |
| **Existing Usage** | Yes — `AINetworkClient.swift`, `DecodeGatewayProvider.swift` |

**Why this technology.** URLSession is the platform-native HTTP networking framework. The existing Decode codebase uses it with async/await for all AI gateway communication. It provides native async/await support, automatic retry with exponential backoff (implemented in `AINetworkClient`), and SSE streaming via `URLSession.bytes`. No third-party networking library is justified — URLSession covers all DDS requirements.

**Which DDS responsibilities it enables.**
- DDS-003 R4: Semantic pass execution — semantic passes invoke AI services via HTTP
- DDS-009 R1: Consumer invocation — reasoning engines invoke AI services via HTTP
- DDS-001 R5: Failure isolation — URLSession provides timeout, cancellation, and error classification for AI-dependent operations (DDS-001:FM-5, FM-2)

**What constraints it imposes.**
- **Gateway dependency.** All AI calls route through the Decode backend gateway. No direct LLM API access from the client (per CLAUDE.md "Server-side intelligence" principle).
- **Timeout configuration.** DDS-001:PR-5 specifies no latency bound for semantic passes. URLSession timeout must be configurable per-request (currently 120s global timeout).
- **Cancellation.** URLSession task cancellation is cooperative — server-side LLM calls run to completion (see CLAUDE.md known limitation "No server-side request cancellation").
- **Module scope.** Used within `ProducerRuntime` (M2, for semantic pass execution) and `ConsumerRuntime` (M6, for reasoning engine invocation). Not imported by other understanding pipeline modules.

**When to reconsider.** Not applicable. URLSession is the platform-native networking framework with no viable alternative for macOS.

---

### TD-6: DispatchSource (FSEvents) — File System Monitoring

| Field | Value |
|-------|-------|
| **Technology** | DispatchSource.makeFileSystemObjectSource (wraps FSEvents/kqueue) |
| **Category** | File system monitoring |
| **Source** | Apple platform SDK (Dispatch + CoreServices) |
| **Version** | macOS 15.0 SDK |
| **Existing Usage** | Yes — `FileWatcherService.swift` in Infrastructure/FileSystem |

**Why this technology.** DispatchSource is the platform-native file system monitoring mechanism for macOS. The existing Decode codebase uses it with debouncing (300ms) and bridges to AsyncStream for modern async consumption. It monitors directory-level changes (not individual files — per CLAUDE.md "Never watch the file directly. Watch parent directory to survive atomic saves").

**Which DDS responsibilities it enables.**
- DDS-007 R1: Change detection — file-level source change events trigger the Update Engine's change set processing pipeline
- DDS-007 PC-1: Change set processing — file system events are the primary input that initiates change detection

**What constraints it imposes.**
- **GCD requirement.** DispatchSource requires a DispatchQueue for event delivery. This is the one area where GCD is used instead of pure Swift Concurrency. The bridge to AsyncStream (already implemented in `FileWatcherService`) converts GCD callbacks into async-compatible events.
- **Debouncing.** Atomic saves (common in editors) produce multiple events. Debouncing is required to coalesce rapid events into single change sets. The existing 300ms debounce window is a starting point; the Update Engine may apply additional coalescing.
- **Directory monitoring.** Monitors parent directories, not individual files. This survives atomic saves but requires filtering to identify relevant file changes within monitored directories.
- **Module scope.** Used within `UpdateEngine` (M7) for change detection input. No other understanding pipeline module monitors the file system.

**When to reconsider.** Only if Apple provides a modern async-native file monitoring API that supersedes DispatchSource. The existing GCD-to-AsyncStream bridge is functional and low-maintenance.

---

### TD-7: Swift Codable + Atomic File I/O — Snapshot Serialization

| Field | Value |
|-------|-------|
| **Technology** | Swift Codable protocol + FileManager atomic writes (temp file → rename) |
| **Category** | Serialization and persistence |
| **Source** | Swift standard library + Foundation |
| **Version** | Swift 6.0 / macOS 15.0 SDK |
| **Existing Usage** | Codable used throughout; atomic file I/O is new for understanding pipeline |

**Why this technology.** DDS-008 specifies snapshot persistence as atomic, whole-state serialization: capture the entire DIR state at a committed epoch and write it as a single file (DDS-008:PC-1). Snapshots are read and written as complete units — they are never queried row-by-row. This is fundamentally different from database access and does not benefit from a database engine.

Codable provides type-safe serialization that is automatically derivable for Swift structs. Atomic file writes (write to temp file, rename on success) satisfy DDS-008 I2 (snapshot atomicity — interrupt during write leaves a valid prior snapshot).

**Alternatives considered.**

| Alternative | Evaluation | Verdict |
|-------------|-----------|---------|
| GRDB/SQLite | Already in project. But snapshots are whole-state read/write, not row-level queries. SQLite would add serialization overhead (rows → units → rows) with no query benefit. The unit store is in-memory; SQLite would duplicate state on disk without providing value. | Rejected — wrong access pattern |
| Protocol Buffers | Efficient binary serialization. But adds a third-party dependency (SwiftProtobuf), requires schema files, and introduces a code generation step. Codable achieves the same goal with zero additional dependencies. | Rejected — unnecessary dependency |
| Property Lists | Apple-native serialization. But limited to specific types, poor performance for large heterogeneous collections, and lacks the type safety of Codable. | Rejected — insufficient type coverage |
| Raw binary encoding | Maximum performance. But fragile (no schema evolution), requires manual serialization code for every type, and provides no debugging visibility. | Rejected — fragility outweighs performance |

**Which DDS responsibilities it enables.**
- DDS-008 R1: Snapshot capture — serialize DIR state (all units, counters, content hash map, deferred queue) to disk
- DDS-008 R2: Snapshot loading — deserialize and populate DIR Runtime on startup
- DDS-008 R5: Crash recovery — atomic writes ensure a valid snapshot always exists on disk (prior or current, never partial)
- DDS-008 R6: Deferred queue persistence — queue state included in snapshot via Codable
- DDS-008 R7: Identity counter and epoch counter persistence — counters included in snapshot
- DDS-008 PC-1: Snapshot capture contract — atomic write guarantees
- DDS-008 RI-1: Snapshot single-epoch integrity — one Codable encode per committed epoch

**What constraints it imposes.**
- **Schema evolution.** Codable's default synthesis does not handle schema migration. If the snapshot format changes (new fields, removed fields, renamed fields), explicit `CodingKeys` and custom `init(from:)` / `encode(to:)` are required. All snapshot-format changes must include migration logic.
- **Encoding format.** The specific encoder (JSONEncoder, PropertyListEncoder, or a custom binary encoder) is an implementation decision. IAG-002 selects Codable as the serialization contract; implementation chooses the encoder.
- **Performance.** Codable serialization is O(n) in the number of units. At alpha scale (~50 files, ~10K units), this is negligible. At larger scales, a more efficient binary format may be needed — see reconsideration conditions.
- **Atomicity.** Atomic file writes require temporary file creation in the same directory as the target file (to ensure same-filesystem rename). The snapshot directory must have write permissions.
- **Module scope.** Codable conformance is declared on `DIRCore` types (M1) so they can be serialized. The serialization logic (encode/decode/write/read) lives in `StorageEngine` (M8).

**When to reconsider.** If snapshot serialization latency exceeds acceptable bounds (e.g., >500ms for a full snapshot at scale), consider replacing JSONEncoder with a binary Codable encoder or switching to a custom binary format. The Codable protocol surface remains stable — only the encoder implementation changes.

---

### TD-8: CryptoKit (SHA-256) — Content Hashing

| Field | Value |
|-------|-------|
| **Technology** | CryptoKit SHA256 |
| **Category** | Cryptographic hashing |
| **Source** | Apple platform SDK |
| **Version** | macOS 15.0 SDK |
| **Existing Usage** | `SafeHashUtility.swift` in Infrastructure/FileSystem uses file hashing |

**Why this technology.** DDS-008 R8 requires per-file content hash tracking for reconciliation support. DDS-007 R1 uses content-hash comparison to determine whether a file has structurally changed. SHA-256 via CryptoKit is the platform-native cryptographic hash function — constant-time, hardware-accelerated on Apple Silicon, collision-resistant, and zero-dependency.

**Which DDS responsibilities it enables.**
- DDS-008 R8: Content hash tracking — maintain per-file content hashes across restarts
- DDS-008 PC-5: Content hash map access — provide hashes for reconciliation
- DDS-007 R1: Change detection — compare file content hashes to determine structural change (DDS-007 I6: content-hash idempotency — no content change → zero invalidations)

**What constraints it imposes.**
- **Hash size.** SHA-256 produces 32-byte digests. At 10K files, the content hash map is ~320KB — negligible.
- **Performance.** SHA-256 is hardware-accelerated on Apple Silicon. File hashing is I/O-bound, not compute-bound.
- **Determinism.** SHA-256 is deterministic — same content always produces same hash. This directly supports DDS-007 I6.
- **Module scope.** Hash computation occurs in `UpdateEngine` (M7, change detection) and `StorageEngine` (M8, content hash map). `DIRCore` (M1) defines the hash value type.

**When to reconsider.** Not applicable. SHA-256 is the standard platform hash function. If performance profiling reveals hashing as a bottleneck (unlikely), xxHash or similar non-cryptographic hashes could be evaluated — but only if collision resistance is determined to be unnecessary for DDS-007 I6 compliance.

---

### TD-9: XcodeGen — Build System

| Field | Value |
|-------|-------|
| **Technology** | XcodeGen (project.yml → Xcode project generation) |
| **Category** | Build system |
| **Source** | Third-party (yonaskolb/XcodeGen) |
| **Version** | Current stable |
| **Existing Usage** | Yes — `project.yml` at project root |

**Why this technology.** The existing Decode project uses XcodeGen to generate its Xcode project from a declarative `project.yml`. IAG-001 specifies 8 framework targets for understanding pipeline modules. XcodeGen supports multi-target projects with inter-target dependencies, which directly enables the module architecture.

**Which DDS responsibilities it enables.**
- All modules: Build-system-enforced module boundaries. Each understanding pipeline module is a framework target with explicit dependency declarations. The import graph from IAG-001 §3 is enforced by XcodeGen target dependencies.

**What constraints it imposes.**
- **Regeneration.** `xcodegen generate` must be run after adding or removing Swift files, or after modifying target configurations (per CLAUDE.md).
- **Target configuration.** Each understanding pipeline module requires a target entry in `project.yml` with its source directory, dependencies, and build settings.
- **SPM integration.** SPM packages (SwiftSyntax, tree-sitter, GRDB) are referenced in `project.yml` and linked to specific targets. Understanding pipeline modules that do not use a package must not link it.
- **Framework targets.** Each understanding pipeline module is a `framework` target. The application target links all 8 framework targets.

**When to reconsider.** If the project migrates to Swift Package Manager for target management (replacing XcodeGen), the module architecture from IAG-001 maps directly to SPM targets. The technology change is mechanical — the module set and dependency graph remain identical.

---

### TD-10: XCTest — Testing Framework

| Field | Value |
|-------|-------|
| **Technology** | XCTest |
| **Category** | Testing framework |
| **Source** | Apple platform SDK |
| **Version** | Xcode 16.2 SDK |
| **Existing Usage** | Yes — `DecodeTests/`, `DecodeIntegrationTests/` |

**Why this technology.** XCTest is the platform-native testing framework. The existing Decode project uses it for all tests. Swift Testing (the new framework introduced in Swift 6) is a viable alternative but is not yet used in the codebase. Per TP-3 (existing stack continuity), XCTest is adopted for the understanding pipeline to maintain consistency.

**Which DDS responsibilities it enables.**
- All DDS documents: Testing requirements sections specify contract tests, state model tests, failure mode tests, and integration tests. XCTest provides the assertion and test organization framework for all of these.
- IAG-001 §8: Test target organization — XCTest bundles map 1:1 to IAG-001 test targets.

**What constraints it imposes.**
- **Test target per module.** Each understanding pipeline module has one XCTest bundle (per IAG-001 TR-1).
- **Async test support.** XCTest supports `async` test methods natively. All cross-module contract tests are async.
- **No macro-based assertions.** XCTest uses `XCTAssert*` functions, not Swift Testing's `#expect` macros. This is consistent with the existing test codebase.

**When to reconsider.** When the project adopts Swift Testing as its primary test framework. The migration is incremental — both frameworks can coexist within a target. This is a team process decision, not an architectural one.

---

### TD-11: os.Logger — Client-Side Observability

| Field | Value |
|-------|-------|
| **Technology** | os.Logger (Unified Logging) |
| **Category** | Observability |
| **Source** | Apple platform SDK (os framework) |
| **Version** | macOS 15.0 SDK |
| **Existing Usage** | Yes — `AppDependencies.swift` uses Logger for startup diagnostics |

**Why this technology.** os.Logger is the platform-native structured logging framework. It provides subsystem/category-based log organization, privacy-aware formatting, log levels, and integration with Console.app and Instruments. The existing Decode codebase uses it for startup diagnostics. Per CLAUDE.md, all `print()` calls must be `#if DEBUG` gated; os.Logger is the production-appropriate alternative.

**Which DDS responsibilities it enables.**
- DDS-001 R7: Producer execution observability — execution metrics, DAG health, cost accounting
- DDS-003 R10: Per-invocation observability — metrics, cost accounting, diagnostics
- DDS-004 R8: Per-family index observability — size, freshness, query performance
- DDS-005 R8: Per-request retrieval observability
- DDS-006 R9: Per-assembly observability
- DDS-007: Change detection, invalidation cascade, pipeline coordination observability
- DDS-008: Snapshot capture, GC execution, crash recovery observability
- DDS-009 R8: Per-invocation consumer observability — reasoning duration, grounding coverage

**What constraints it imposes.**
- **No release-build logging in current configuration.** Per CLAUDE.md known limitation, `os.Logger` is not active in release builds. Understanding pipeline observability relies on server-side analytics (request_logs, analytics_events) for production monitoring, with os.Logger available for development diagnostics.
- **Subsystem/category convention.** Each understanding pipeline module uses `subsystem: "com.decode.understanding"` with a module-specific category (e.g., `category: "update-engine"`).
- **Privacy.** Log messages containing file paths or source content must use `.private` formatting to prevent leaking user code into system logs.

**When to reconsider.** If production observability requirements emerge that need client-side structured telemetry beyond server-side analytics. In that case, evaluate whether os.Logger in release builds (with appropriate privacy controls) is sufficient, or whether a dedicated telemetry framework is needed.

---

## 6. Alternatives Considered (Summary)

### Reconsideration Policy

Rejected alternatives are reconsidered **only** when the reassessment conditions specified in the "When to reconsider" field of the corresponding Technology Decision record are satisfied. A rejected alternative does not re-enter evaluation because it has improved in isolation — it re-enters evaluation only when the conditions that led to the original selection have changed. This prevents speculative technology churn.

For brevity, alternatives for each technology are recorded in the decision record above. This section summarizes the rejected alternative categories.

| Category | Rejected Alternatives | Reason |
|----------|----------------------|--------|
| Concurrency | GCD (Grand Central Dispatch) | Legacy for new Swift 6 code. No compile-time data race safety. Already superseded in codebase. |
| Concurrency | Combine | Not used in codebase. AsyncSequence/AsyncStream cover all reactive patterns needed. |
| Persistence | GRDB/SQLite for snapshots | Wrong access pattern — snapshots are whole-state read/write, not row-level queries. |
| Persistence | Protocol Buffers | Unnecessary dependency — Codable achieves same goal with zero additional packages. |
| Persistence | Core Data | Wrong abstraction level — designed for object graph persistence, not bulk serialization. |
| Networking | Alamofire / third-party HTTP | URLSession with async/await is fully capable. No justification for additional dependency. |
| File monitoring | FSEvents API (direct) | Lower-level than DispatchSource with no added capability. DispatchSource wraps FSEvents with better lifecycle management. |
| Testing | Swift Testing | Not yet adopted in codebase. Can be migrated incrementally when team decides. |
| Testing | Quick/Nimble | Third-party test framework. XCTest is sufficient. Additional dependency not justified. |
| Hashing | xxHash / non-cryptographic | Could be faster but collision resistance is valuable for DDS-007 I6 compliance. SHA-256 is hardware-accelerated and sufficient. |

---

## 7. Constraints Summary

### Constraints Imposed on Implementation

| Constraint ID | Technology | Constraint | Affected Modules |
|--------------|------------|------------|-----------------|
| **TC-1** | Swift 6.0 | All types crossing concurrency boundaries must be `Sendable` | All modules |
| **TC-2** | Swift 6.0 | `SWIFT_STRICT_CONCURRENCY = complete` — no data race suppressions without documented justification | All modules |
| **TC-3** | Swift Concurrency | Cross-module protocol methods must be `async` unless explicitly synchronous | All modules |
| **TC-4** | Swift Concurrency | `@MainActor` prohibited in understanding pipeline modules — used only in Presentation and composition root | M1–M8 |
| **TC-5** | Swift Concurrency | Structured concurrency (TaskGroup) for parallelizable pipeline work; unstructured Task for lifecycle management only | M2, M7 |
| **TC-6** | SwiftSyntax | Version must match Swift compiler version (600.x = Swift 6.0) | M2 |
| **TC-7** | SwiftTreeSitter | Grammar packages pinned to exact versions; updates require individual parse-correctness testing | M2 |
| **TC-8** | URLSession | All AI calls through Decode backend gateway — no direct LLM API access | M2, M6 |
| **TC-9** | URLSession | Request timeout configurable per-request; no global timeout for semantic passes | M2, M6 |
| **TC-10** | DispatchSource | File monitoring uses GCD-to-AsyncStream bridge; debouncing required | M7 |
| **TC-11** | Codable | Snapshot format changes require explicit migration logic (custom CodingKeys / init(from:)) | M1 (types), M8 (logic) |
| **TC-12** | Codable | Encoder selection (JSON/binary/plist) is implementation decision; Codable protocol is the contract | M8 |
| **TC-13** | CryptoKit | SHA-256 digests stored as 32-byte values; hash type defined in `DIRCore` | M1, M7, M8 |
| **TC-14** | XcodeGen | `xcodegen generate` required after adding/removing files or modifying targets | All modules |
| **TC-15** | XCTest | One test bundle per module; async test methods for cross-module contract tests | All test targets |
| **TC-16** | os.Logger | `subsystem: "com.decode.understanding"` with module-specific category; `.private` for user content | All modules |

---

## 8. Migration Strategy

### Migration Principle

Every technology in this document can be replaced without modifying the DDS specifications. The DDS layer is technology-neutral. The IAG maps technologies to DDS requirements; replacing a technology requires updating the IAG mapping, not the DDS contracts.

### Migration Process

For any technology replacement:

1. **Identify affected modules** using the constraint table (§7) and the traceability map (§12).
2. **Verify DDS coverage** — confirm the replacement technology covers all DDS responsibilities listed in the original decision record.
3. **Assess protocol impact** — if the replacement changes the async/sync nature of operations, IAG-003 (Runtime Architecture) must be updated.
4. **Update IAG-002** — revise the decision record with the new technology, rationale, and constraints.
5. **Implement** — replace within affected modules. Protocol boundaries from IAG-001 contain the blast radius.

### Per-Technology Migration Paths

| Technology | Replacement Scenario | Blast Radius | Migration Complexity |
|------------|---------------------|-------------|---------------------|
| SwiftSyntax | Swift introduces built-in parsing API | `ProducerRuntime` only | Low — parser protocol isolates the dependency |
| SwiftTreeSitter | Alternative multi-language parser emerges | `ProducerRuntime` only | Low — parser protocol isolates the dependency |
| URLSession | Never — platform-native | N/A | N/A |
| DispatchSource | Apple provides async file monitoring | `UpdateEngine` only | Low — AsyncStream interface unchanged; only source changes |
| Codable encoder | Performance requires binary encoder | `StorageEngine` only (encoder swap) | Low — Codable protocol unchanged; only encoder changes |
| Codable protocol | Performance requires custom serialization | `DIRCore` (types) + `StorageEngine` (logic) | Medium — requires custom serialize/deserialize for all unit types |
| XcodeGen | Migration to SPM | All targets (mechanical) | Medium — target definitions move from project.yml to Package.swift |
| XCTest | Migration to Swift Testing | All test targets (incremental) | Low — both frameworks coexist; migrate target-by-target |

---

## 9. Versioning Policy

### Dependency Version Rules

| Rule | Statement |
|------|-----------|
| **VR-1** | Third-party dependencies are pinned to **exact versions** unless a range is required for compatibility. Exact pinning prevents surprise breakage from upstream changes. |
| **VR-2** | SwiftSyntax version must match the Swift compiler version used by the project. When the project upgrades Swift, SwiftSyntax is upgraded simultaneously. |
| **VR-3** | Tree-sitter grammar packages are pinned to exact versions. Each grammar is updated and tested individually — never batch-updated. |
| **VR-4** | SwiftTreeSitter uses a **minimum version** constraint (`from: 0.10.0`) because it is a Swift wrapper around tree-sitter's C library. Minor version updates provide bug fixes and compatibility improvements without API breakage. |
| **VR-5** | Platform SDK dependencies (CryptoKit, URLSession, DispatchSource, os.Logger, XCTest) are version-locked to the deployment target (macOS 15.0). They require no explicit version management. |
| **VR-6** | GRDB is pinned to exact version (7.5.0). It is used by the existing application target, not by understanding pipeline modules. Understanding pipeline modules do not depend on GRDB. |

### Version Update Process

1. Update the version in `project.yml`.
2. Run `xcodegen generate`.
3. Build all affected targets.
4. Run all affected test targets.
5. If a grammar package was updated, run parse-correctness tests against the affected language's test fixtures.

---

## 10. Platform Compatibility Requirements

All platform versions listed below are **minimum supported versions** unless explicitly stated otherwise. Future releases of macOS, Xcode, and Swift are adopted when they satisfy all technology constraints in this document (particularly TC-6: SwiftSyntax version coupling to Swift compiler version).

| Requirement | Value | Rationale |
|-------------|-------|-----------|
| **Deployment target** | macOS 15.0 (minimum) | Required for Swift 6.0 runtime, modern SwiftUI, and `@Observable` macro. |
| **Xcode version** | 16.2 (minimum) | Required for Swift 6.0 compiler with strict concurrency. |
| **Swift version** | 6.0 (minimum) | Enables strict concurrency checking and modern language features. |
| **Architecture** | Apple Silicon (arm64) + Intel (x86_64) | Universal binary. CryptoKit SHA-256 is hardware-accelerated on Apple Silicon. |
| **Signing** | Apple Development (Team P5Y864DV5S) | Required for Accessibility and Input Monitoring permissions. CDHash-bound permissions. |
| **Sandbox** | Disabled | Required for file system monitoring of arbitrary directories (user's code projects). |
| **Entitlements** | Accessibility, Input Monitoring, Screen Recording | Existing Decode requirements. Understanding pipeline adds no new entitlements. |

---

## 11. Cross-Module Technology Usage Rules

### Which Modules Use Which Technologies

| Technology | M1 DIRCore | M2 Producer | M3 Index | M4 Retrieval | M5 Context | M6 Consumer | M7 Update | M8 Storage |
|-----------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| Swift 6.0 | ● | ● | ● | ● | ● | ● | ● | ● |
| Swift Concurrency | — | ● | ● | ● | ● | ● | ● | ● |
| SwiftSyntax | — | ● | — | — | — | — | — | — |
| SwiftTreeSitter | — | ● | — | — | — | — | — | — |
| URLSession | — | ● | — | — | — | ● | — | — |
| DispatchSource | — | — | — | — | — | — | ● | — |
| Codable | ● | — | — | — | — | — | — | ● |
| CryptoKit | ● | — | — | — | — | — | ● | ● |
| os.Logger | — | ● | ● | ● | ● | ● | ● | ● |
| XCTest | (tests) | (tests) | (tests) | (tests) | (tests) | (tests) | (tests) | (tests) |

`●` = direct dependency. `—` = not used. `(tests)` = test target only.

**Legend for DIRCore:** DIRCore uses Swift 6.0 for type definitions. It does not use Swift Concurrency runtime features (no actors, no async methods). It declares Codable conformance on types for StorageEngine serialization. It defines hash value types using CryptoKit types.

### Technology Isolation Rules

| Rule | Statement |
|------|-----------|
| **TI-1** | A module must not link a framework it does not directly use. SPM packages are linked only to the targets listed in the matrix above. |
| **TI-2** | Third-party framework types must not appear in cross-module protocol signatures. If SwiftSyntax defines a type, it must be converted to a `DIRCore` type before crossing the `ProducerRuntime` boundary. |
| **TI-3** | No understanding pipeline module depends on GRDB. GRDB is an application-layer dependency for session/entity storage. The understanding pipeline's persistence is handled exclusively by Codable + file I/O in `StorageEngine`. |
| **TI-4** | Framework-specific error types must not propagate across module boundaries. Each module converts framework errors to its own error type or to a `DIRCore`-defined error protocol before crossing the boundary. |
| **TI-5** | Codable conformance is declared on `DIRCore` types but the serialization/deserialization logic (encoder selection, file I/O) is exclusively in `StorageEngine`. No module other than `StorageEngine` serializes or deserializes DIR types. |

---

## 12. Traceability: DDS Responsibilities to Technology Choices

### Traceability Map

Every technology decision traces to specific DDS responsibilities. This map is the inverse of the decision records — organized by DDS subsystem rather than by technology.

#### DDS-001: Producer Runtime

| DDS Responsibility | Technology | Decision Record |
|-------------------|------------|-----------------|
| R1 (Producer Registry) | Swift 6.0, Swift Concurrency | TD-1, TD-2 |
| R2 (Pass DAG) | Swift 6.0 | TD-1 |
| R3 (Execute Producers) — Swift frontends | SwiftSyntax | TD-3 |
| R3 (Execute Producers) — non-Swift frontends | SwiftTreeSitter + grammars | TD-4 |
| R3 (Execute Producers) — semantic passes | URLSession (AI gateway) | TD-5 |
| R5 (Failure Isolation) | Swift Concurrency (Task cancellation) | TD-2 |
| R7 (Observability) | os.Logger | TD-11 |

#### DDS-002: DIR Runtime Model

| DDS Responsibility | Technology | Decision Record |
|-------------------|------------|-----------------|
| R1 (Unit Store) | Swift 6.0, Swift Concurrency (isolation) | TD-1, TD-2 |
| R2 (Intake Validation) | Swift 6.0 | TD-1 |
| R3 (Immutability) | Swift 6.0 (value types, let bindings) | TD-1 |
| R6 (Epoch Counter) | Swift 6.0 | TD-1 |
| R7 (Read Access) | Swift Concurrency (async read path) | TD-2 |
| Snapshot serialization of unit types | Codable | TD-7 |

#### DDS-003: Pass Runtime

| DDS Responsibility | Technology | Decision Record |
|-------------------|------------|-----------------|
| R4 (Execute Passes) — deterministic | SwiftSyntax, SwiftTreeSitter | TD-3, TD-4 |
| R4 (Execute Passes) — semantic | URLSession (AI gateway) | TD-5 |
| R6 (Changed Output Detection) | Swift 6.0 | TD-1 |
| R7 (Cancellation) | Swift Concurrency (Task.isCancelled) | TD-2 |
| R10 (Observability) | os.Logger | TD-11 |

#### DDS-004: Index Runtime

| DDS Responsibility | Technology | Decision Record |
|-------------------|------------|-----------------|
| R1 (Index Families) | Swift 6.0, Swift Concurrency (isolation) | TD-1, TD-2 |
| R2 (Startup Construction) | Swift 6.0 | TD-1 |
| R3 (Incremental Update) | Swift 6.0 | TD-1 |
| R8 (Observability) | os.Logger | TD-11 |

#### DDS-005: Retrieval Runtime

| DDS Responsibility | Technology | Decision Record |
|-------------------|------------|-----------------|
| R1 (Evidence Retrieval) | Swift 6.0, Swift Concurrency | TD-1, TD-2 |
| R8 (Observability) | os.Logger | TD-11 |

#### DDS-006: Context Assembly Runtime

| DDS Responsibility | Technology | Decision Record |
|-------------------|------------|-----------------|
| R1 (Context Frames) | Swift 6.0 | TD-1 |
| R3 (Budget Enforcement) | Swift 6.0 | TD-1 |
| R9 (Observability) | os.Logger | TD-11 |

#### DDS-007: Update Engine Runtime

| DDS Responsibility | Technology | Decision Record |
|-------------------|------------|-----------------|
| R1 (Change Detection) — file-level | DispatchSource, CryptoKit SHA-256 | TD-6, TD-8 |
| R1 (Change Detection) — entity-level | SwiftSyntax, SwiftTreeSitter (via ProducerRuntime) | TD-3, TD-4 |
| R2 (Invalidation Cascade) | Swift 6.0 | TD-1 |
| R4 (Synchronous Pipeline) | Swift Concurrency (structured concurrency) | TD-2 |
| R5 (Deferred Pipeline) | Swift Concurrency (Task, scheduling) | TD-2 |
| R7 (Epoch Advancement) | Swift 6.0 | TD-1 |
| R9 (Sequential Processing) | Swift Concurrency (serialization) | TD-2 |
| Observability | os.Logger | TD-11 |

#### DDS-008: Storage Engine Runtime

| DDS Responsibility | Technology | Decision Record |
|-------------------|------------|-----------------|
| R1 (Snapshot Persistence) | Codable + atomic file I/O | TD-7 |
| R2 (Snapshot Loading) | Codable | TD-7 |
| R3 (Grounding Dependency Map) | Swift 6.0 | TD-1 |
| R4 (Garbage Collection) | Swift 6.0 | TD-1 |
| R5 (Crash Recovery) | Atomic file I/O (temp → rename) | TD-7 |
| R6 (Deferred Queue Persistence) | Codable (included in snapshot) | TD-7 |
| R7 (Counter Persistence) | Codable (included in snapshot) | TD-7 |
| R8 (Content Hash Tracking) | CryptoKit SHA-256 | TD-8 |
| Observability | os.Logger | TD-11 |

#### DDS-009: Consumer Runtime

| DDS Responsibility | Technology | Decision Record |
|-------------------|------------|-----------------|
| R1 (Consumer Invocation) | Swift Concurrency, URLSession | TD-2, TD-5 |
| R2 (Reasoning Engine Registry) | Swift 6.0 | TD-1 |
| R3 (Contract Enforcement) | Swift 6.0 | TD-1 |
| R6 (Conversation State) | Swift 6.0 (in-memory, transient per DDS-009 RI-9) | TD-1 |
| R8 (Observability) | os.Logger | TD-11 |
| R9 (Demand Signals) | Swift Concurrency (async protocol call) | TD-2 |

### Coverage Verification

Every DDS responsibility across all 9 subsystems traces to at least one technology decision. No DDS responsibility lacks a technology enabler. No technology decision lacks a DDS justification.

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 0.1 | 2026-06-28 | Initial draft. 11 technology decision records, alternatives analysis, constraints, migration strategies, versioning policy, platform requirements, cross-module usage rules, complete DDS traceability. |
| 0.2 | 2026-06-28 | CTO review revisions: (1) Added §3 Technology Decision Lifetime Categories — classified all 11 TDs as Foundational, Replaceable, or Commodity with justifications. (2) Added §4 Technology Decision Ownership — assigned engineering owner to all 11 TDs. (3) Clarified §10 Platform Compatibility Requirements — macOS 15.0, Xcode 16.2, Swift 6.0 are minimum supported versions. (4) Added reconsideration policy to §6 Alternatives — rejected alternatives reconsidered only when reassessment conditions of the corresponding TD are satisfied. Renumbered all sections for consistency. |

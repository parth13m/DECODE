# VAS-001: Virtual Session Architecture Specification

**Status**: Canonical  
**Version**: 1.0  
**Scope**: Cross-platform architecture for Virtual Session memory  
**Audience**: Any engineer implementing Decode on any platform  

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [High-Level Architecture](#2-high-level-architecture)
3. [Core Concepts](#3-core-concepts)
4. [Complete Object Model](#4-complete-object-model)
5. [Working Memory](#5-working-memory)
6. [Investigations](#6-investigations)
7. [Topic Switching](#7-topic-switching)
8. [Compression](#8-compression)
9. [Prompt Augmentation](#9-prompt-augmentation)
10. [Explanation Lifecycle](#10-explanation-lifecycle)
11. [Memory Inspector](#11-memory-inspector)
12. [Persistence](#12-persistence)
13. [State Machine](#13-state-machine)
14. [Concurrency](#14-concurrency)
15. [Error Handling](#15-error-handling)
16. [Invariants](#16-invariants)
17. [Performance](#17-performance)
18. [Testing Strategy](#18-testing-strategy)
19. [Future Extension Points](#19-future-extension-points)
20. [Appendix](#20-appendix)

---

## 1. Introduction

### 1.1 Purpose

This document is the canonical architecture specification for Decode's **Virtual Session** system. It defines every concept, model, algorithm, lifecycle, state transition, invariant, and interaction required to build a functionally identical implementation on any platform.

Virtual Session is an application-layer feature. It is not a pipeline module. It does not modify the understanding pipeline, the reasoning engines, or the DIR. It operates alongside the explanation pipeline as a cross-mode memory layer that accumulates and reuses knowledge across successive explanations.

### 1.2 Motivation

Decode explains code. Each explanation is stateless by default: the user selects code, Decode explains it, and the explanation is discarded. If the user asks about a related piece of code five minutes later, the second explanation has no awareness that the first explanation ever happened.

This is wasteful. A developer investigating authentication does not randomly switch to database indexing. They follow a thread: authentication flow, then token validation, then keychain storage. Each explanation builds on what came before.

Virtual Session solves this by maintaining a bounded, evolving memory of what the user has learned during an investigation. When the user asks about token validation, the explanation can reference the authentication knowledge already established, producing richer explanations without redundancy.

### 1.3 Product Problem

Without Virtual Session, Decode produces isolated explanations. The user must mentally integrate knowledge across multiple interactions. Explanations repeat foundational context. Related concepts are explained from scratch each time.

With Virtual Session, Decode maintains conversational continuity:

- If the user learned that "WorkspaceResolver scores workspaces by entity containment" in a previous explanation, the next explanation about `WorkspaceManager` can reference this understanding directly.
- If the user has been investigating authentication for the past 20 minutes, the system prompt tells the LLM about this ongoing investigation, producing explanations that build on prior knowledge.

### 1.4 User Experience Goals

1. **Zero configuration.** Virtual Session is a single toggle. No setup, no categories, no tagging.
2. **Invisible when off.** No performance impact, no storage, no state when disabled.
3. **Transparent when on.** The Memory Inspector shows exactly what the system remembers.
4. **Non-destructive.** Explanations still work perfectly without Virtual Session. It augments; it never gates.
5. **Bounded.** Memory does not grow without limit. It compresses, evicts, and resets to stay within fixed budgets.
6. **Topic-aware.** When the user switches topics, the system detects this and resets rather than injecting irrelevant context.

### 1.5 Design Philosophy

**Working Memory is operational. Investigations are archival.**

Virtual Session maintains two parallel knowledge structures. Working Memory is a single bounded summary that is unconditionally injected into every prompt. It represents "what the LLM needs to know right now." Investigations are structured records of knowledge organized by topic. They are the historical archive.

**Deterministic first, LLM second.**

Understanding extraction, topic switching, knowledge evolution, and eviction are all deterministic algorithms. The only LLM call in the entire Virtual Session system is optional compression of Working Memory when it exceeds its character budget. If the LLM is unavailable, deterministic compression handles it.

**Bounded by design, not by cleanup.**

Every data structure has a hard limit. Working Memory: 1000 characters. Investigation knowledge: 600 characters. Total insights: 20. Total investigations: 5. Session lifetime: 2 hours of inactivity. These are not cleanup thresholds; they are architectural invariants.

**Unconditional injection.**

Working Memory is injected into every prompt when non-empty. There is no relevance scoring, no threshold, no decision logic. If the user has Working Memory, it goes into the prompt. This is a deliberate simplification that avoids false negatives (failing to inject relevant context) at the cost of occasionally injecting context that is slightly off-topic. The topic switching system handles the off-topic case by resetting Working Memory when the user changes subjects.

---

## 2. High-Level Architecture

### 2.1 System Diagram

```
                    User Interaction
                         |
                         v
            +-------------------------+
            |     Mode Coordinator    |    (Selection, Screenshot, Session)
            +-------------------------+
                    |            |
           [1. Before LLM]   [4. After LLM]
                    |            |
                    v            v
        +----------------+  +--------------------+
        | Prompt Assembly |  | Understanding      |
        | (inject WM)    |  | Extraction          |
        +----------------+  | (deterministic)     |
                |            +--------------------+
                v                     |
        +----------------+           v
        | Explanation    |   +--------------------+
        | Engine (LLM)   |   | VirtualSession     |
        +----------------+   | Manager            |
                |            +--------------------+
                v                |           |
        +----------------+     v           v
        | Explanation    |  +-------+  +--------+
        | Result (HUD)   |  |Working|  |Investi-|
        +----------------+  |Memory |  |gations |
                             +-------+  +--------+
                                |           |
                                v           v
                          +--------------------+
                          | Persistence (JSON) |
                          +--------------------+
```

### 2.2 Data Flow

The data flow for a single explanation with Virtual Session enabled:

1. **Before the LLM call**: The coordinator retrieves the current Working Memory content from the VirtualSessionManager and appends it to the system prompt.

2. **LLM call**: The explanation engine generates an explanation. The LLM sees the Working Memory content as part of its system prompt, enabling it to build on prior knowledge.

3. **After the LLM call**: When the explanation stream completes, the coordinator:
   a. Extracts a concise understanding from the explanation text (deterministic, no LLM).
   b. Records the understanding as an Insight into the VirtualSessionManager.

4. **Inside the VirtualSessionManager**, recording an insight triggers:
   a. Investigation routing (continue existing investigation or start a new one).
   b. Investigation knowledge evolution (integrate the new understanding).
   c. Working Memory evolution (integrate the new understanding, check for topic switch).
   d. Storage limit enforcement (evict oldest data if bounds exceeded).
   e. Persistence to disk.
   f. Optional: async LLM compression of Working Memory if over character budget.

### 2.3 Integration Points

Virtual Session integrates with the rest of Decode at exactly three points per mode coordinator:

| Point | When | What |
|-------|------|------|
| Prompt injection | Before LLM call | `workingMemoryBlock()` appended to system prompt |
| Understanding extraction | After stream completes | `extractUnderstanding()` called on explanation text |
| Insight recording | After extraction | `recordInsight()` called with extracted understanding |

There is also a UI integration:

| Point | When | What |
|-------|------|------|
| Toggle | User enables/disables | `handleToggleChanged()` starts/ends session |
| Inspector | User opens popover | Reads `activeSession` to display memory state |
| Restore | App launch | `restore()` loads persisted session |
| AI provider | Deferred startup | `aiProvider` closure wired for compression |

### 2.4 Relationship to the Understanding Pipeline

Virtual Session is **not** a pipeline module. It does not appear in IAG-001. It does not participate in the DIR, the producer runtime, the index runtime, or any pipeline stage.

Virtual Session is an application-layer feature that sits beside the pipeline. It consumes the output of the explanation engine (the explanation text) and produces prompt augmentation (Working Memory injection) that is appended to the system prompt before the LLM call.

In Session Mode, the coordinator may use either the legacy explanation path or the pipeline path. Both paths inject Working Memory the same way and both paths record insights the same way. The pipeline path does **not** inject Working Memory into reasoning engines — reasoning engines are frozen pipeline modules. Working Memory is injected into the system prompt at the coordinator level, before either path diverges.

---

## 3. Core Concepts

### 3.1 Virtual Session

A **Virtual Session** is a temporary, bounded memory container that spans all Decode modes (Selection, Screenshot, Session, Follow-up). It starts when the user enables the Virtual Session toggle and ends when they disable it or when the session expires due to inactivity.

A session contains:
- An ordered sequence of **Investigations** (capped at 5).
- A single **Working Memory** (optional, for backward compatibility with sessions that predate this feature).

A session does NOT contain:
- The explanation text (explanations are transient).
- The user's code (code is never stored in the session).
- Any user preferences or configuration.

### 3.2 Working Memory

**Working Memory** is a continuously evolving, bounded summary of the user's current investigation topic. It is the **only** component of Virtual Session that is injected into LLM prompts.

Key characteristics:
- **Singular**: exactly one Working Memory per session, or none.
- **Bounded**: hard limit of 1000 characters. Compressed to approximately 250 characters when the limit is exceeded.
- **Topic-aware**: resets when the user switches to a different topic.
- **Unconditional**: if content is non-empty, it is always injected. No scoring, no threshold.
- **Separate from Investigations**: Working Memory is operational (what the LLM needs now). Investigations are archival (what the user has learned historically).

### 3.3 Investigation

An **Investigation** is a coherent line of inquiry within a session. It represents a **living knowledge document** that evolves as the user asks related questions.

An investigation starts implicitly when a new insight has low structural affinity with the active investigation's anchor. It ends implicitly when the next insight starts a new investigation, or when the session ends.

An investigation contains:
- A **theme**: a one-sentence characterization (e.g., "Understanding Auth.swift").
- An ordered sequence of **Insights** (supporting evidence).
- A **structural anchor**: accumulated file paths, entity names, module names, and relationship targets.
- A **current understanding**: synthesized knowledge evolved from insights (the canonical knowledge representation).
- **Knowledge sentences**: sentence-level tracking for the evolution algorithm.
- **Known files** and **known entities**: accumulated metadata from insight contexts.

### 3.4 Insight

An **Insight** is a distilled understanding gained from a single Decode interaction. It represents what the user *learned*, not what they *requested*.

Example insights:
- "WorkspaceResolver scores workspaces by entity containment, with pinned workspace as unconditional override."
- "The auth flow stores SHA-256 hash server-side, raw token client-side."

An insight is extracted deterministically from the LLM's explanation text (no LLM call). It carries structural metadata (file path, entity name, module, language, etc.) used for retrieval scoring and investigation boundary detection.

### 3.5 Investigation Anchor

An **Investigation Anchor** is the accumulated structural knowledge about what an investigation covers. It is a set-based data structure that grows as insights join the investigation:

- **File paths**: absolute paths of files involved.
- **Entity names**: qualified names (e.g., "WorkspaceResolver.resolve").
- **Module names**: architectural modules (e.g., "Application", "Infrastructure").
- **Layers**: architectural layers (e.g., "application", "domain").
- **Related entity names**: entities encountered as call targets, conformance targets, inheritance targets.
- **Workspace ID**: the associated workspace, if any.

The anchor is used for two purposes:
1. **Investigation boundary detection**: should a new insight continue the active investigation or start a new one?
2. **Working Memory topic switching**: should Working Memory reset because the user changed topics?

### 3.6 Topic Fingerprint

Virtual Session uses a **topic fingerprint** to detect when the user has switched topics. This is a two-layer system:

- **Layer 1 (Structural)**: For contexts with structural data (Session Mode), the fingerprint is the Investigation Anchor. Structural overlap (file, entity, module, layer) indicates topic continuity.
- **Layer 2 (Semantic)**: For contexts without structural data (Selection/Screenshot modes), the fingerprint is a list of **topic keywords** extracted from understandings. Zero keyword overlap with sufficient evidence indicates a topic switch.

### 3.7 Compression

**Compression** is the process of reducing Working Memory content when it exceeds the 1000-character budget. It has two implementations:

- **LLM compression** (primary): sends the Working Memory content to the LLM with a prompt requesting compression to approximately 250 characters. Runs asynchronously. Validates the response (30-250 characters). Falls back to deterministic on failure.
- **Deterministic compression** (fallback): evicts the least-important sentences based on information density, reinforcement count, and recency until the content fits within the 250-character target.

Compression never blocks explanations. It runs in a background task that can be cancelled and replaced.

### 3.8 Prompt Augmentation

**Prompt augmentation** is the injection of Working Memory content into the system prompt before the LLM call. The format is:

```
WORKING MEMORY (your evolving understanding from this session):
{content}
Build on this understanding. Do not repeat it.
```

This block is appended to the end of the system prompt string with a `\n\n` separator.

### 3.9 Memory Inspector

The **Memory Inspector** is a UI popover that displays the current state of the Virtual Session. It shows statistics (investigation count, insight count, memory size), Working Memory content with topic keywords, and each investigation with its theme, current understanding, known files, and known entities.

### 3.10 Persistence

Virtual Session is persisted as a single JSON file at a well-known path. Persistence is incremental: the file is rewritten after every mutation (insight recording, session start/end, compression). This ensures that unexpected termination never loses more than the current in-flight mutation.

### 3.11 Lifecycle

A Virtual Session has a simple lifecycle:

1. **Created**: when the user enables the toggle or the app restores a persisted session.
2. **Active**: accepting insights, evolving Working Memory, persisting state.
3. **Expired**: automatically after 2 hours of inactivity.
4. **Ended**: when the user disables the toggle or the session expires.

### 3.12 State

Virtual Session state is entirely contained in the `VirtualSession` object model. There is no external state, no database tables, no server-side storage. The session is a local, transient, JSON-serializable value type.

---

## 4. Complete Object Model

### 4.1 VirtualSession

**Purpose**: Root container for a single investigation session.

**Responsibilities**:
- Holds the ordered sequence of investigations.
- Holds the Working Memory.
- Computes aggregate statistics (total insight count, total character count, last activity timestamp).
- Determines expiration based on inactivity.

**Fields**:

| Field | Type | Mutability | Description |
|-------|------|------------|-------------|
| `id` | UUID | Immutable | Unique session identifier. Assigned at creation. |
| `startedAt` | DateTime | Immutable | Session creation timestamp. |
| `investigations` | Array\<Investigation\> | Mutable | Ordered sequence of investigation threads. |
| `workingMemory` | WorkingMemory? | Mutable | Current working memory. `null` for legacy sessions. |

**Computed Properties**:

| Property | Type | Derivation |
|----------|------|------------|
| `activeInvestigation` | Investigation? | Last element of `investigations`, or null. |
| `totalInsightCount` | Int | Sum of insight counts across all investigations. |
| `totalCharacterCount` | Int | Sum of `understanding.length` across all insights in all investigations. |
| `lastActivityTimestamp` | DateTime | Timestamp of the most recent insight, or `startedAt` if no insights exist. |
| `isExpired(now)` | Bool | `true` if `now - lastActivityTimestamp > expirationInterval`. |

**Constants**:

| Constant | Value | Purpose |
|----------|-------|---------|
| `maxInsightCount` | 20 | Maximum insights retained across all investigations. |
| `maxTotalCharacters` | 3000 | Maximum total character budget across all insight understanding texts. |
| `maxInvestigationCount` | 5 | Maximum investigation threads per session. |
| `expirationInterval` | 7200 seconds (2 hours) | Inactivity duration after which the session expires. |

**Lifecycle**: Created by the manager when the user enables the toggle. Destroyed when the user disables the toggle or the session expires.

**Ownership**: Owned by the VirtualSessionManager.

**Persistence**: Serialized as JSON. All fields participate in serialization. `workingMemory` is optional for backward compatibility.

**Serialization**: JSON with ISO8601 date encoding. Pretty-printed with sorted keys for debugging readability.

### 4.2 Investigation

**Purpose**: A coherent line of inquiry — a living knowledge document that evolves as insights accrue.

**Responsibilities**:
- Stores insights as supporting evidence.
- Maintains a synthesized `currentUnderstanding` that is the canonical knowledge representation.
- Tracks structural scope via anchor.
- Tracks known files and entities for display in the Memory Inspector.

**Fields**:

| Field | Type | Mutability | Description |
|-------|------|------------|-------------|
| `id` | UUID | Immutable | Unique investigation identifier. |
| `startedAt` | DateTime | Immutable | Investigation creation timestamp. |
| `theme` | String | Mutable | 1-sentence characterization. Updated when scope expands. |
| `insights` | Array\<Insight\> | Mutable | Ordered supporting evidence. |
| `anchor` | InvestigationAnchor | Mutable | Accumulated structural context. Grows as insights join. |
| `currentUnderstanding` | String? | Mutable | Canonical synthesized knowledge. `null` for legacy sessions. |
| `knowledgeSentences` | Array\<KnowledgeSentence\>? | Mutable | Sentence-level tracking for evolution. `null` for legacy. |
| `knownFiles` | Set\<String\>? | Mutable | File names this investigation has touched. `null` for legacy. |
| `knownEntities` | Set\<String\>? | Mutable | Entity names encountered. `null` for legacy. |

**Lifecycle**: Created when a new insight has low structural affinity with the active investigation. Never explicitly destroyed — evicted when investigation count exceeds the maximum, or when the session ends.

**Relationship with Working Memory**: Independent. An investigation is archival knowledge organized by structural scope. Working Memory is operational knowledge organized by temporal recency. They evolve in parallel from the same insight stream but serve different purposes.

### 4.3 Insight

**Purpose**: A distilled understanding from a single Decode interaction.

**Responsibilities**:
- Records *what the user learned*, not what they requested.
- Carries structural metadata for retrieval scoring.

**Fields**:

| Field | Type | Mutability | Description |
|-------|------|------------|-------------|
| `id` | UUID | Immutable | Unique insight identifier. |
| `timestamp` | DateTime | Immutable | When the insight was recorded. |
| `mode` | InsightMode | Immutable | Which Decode mode produced this insight. |
| `understanding` | String | Immutable | Concise characterization of what was learned. Max ~200 chars. |
| `context` | InsightContext | Immutable | Structural metadata for retrieval scoring. |

**Lifecycle**: Created when a coordinator calls `recordInsight()`. Immutable after creation. Evicted when storage limits are exceeded (FIFO from oldest investigation).

### 4.4 InsightMode

**Purpose**: Identifies which Decode mode produced an insight.

**Values**:

| Value | String | Description |
|-------|--------|-------------|
| `selection` | `"selection"` | Text selection explanation. |
| `screenshot` | `"screenshot"` | Screenshot OCR explanation. |
| `session` | `"session"` | Workspace/session question explanation. |
| `followUp` | `"follow_up"` | Follow-up question. |

### 4.5 InsightContext

**Purpose**: Structural metadata attached to each insight, drawn from Decode's existing platform knowledge at request time. Used for structural affinity scoring during retrieval and investigation boundary detection.

**Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `filePath` | String? | Absolute file path, if known (Session Mode). |
| `fileName` | String? | File name (e.g., "WorkspaceResolver.swift"). |
| `entityName` | String? | Resolved entity name (e.g., "WorkspaceResolver.resolve"). |
| `entityType` | String? | Entity kind (e.g., "function", "class", "protocol"). |
| `moduleName` | String? | Module name derived from directory (e.g., "Application"). |
| `layer` | String? | Architectural layer (e.g., "application", "domain"). |
| `fileRole` | String? | File role from identity classification (e.g., "service", "coordinator"). |
| `language` | String? | Detected programming language. |
| `sourceApp` | String? | Source application name (e.g., "Xcode", "VS Code"). |
| `workspaceID` | UUID? | Associated workspace ID. |
| `relatedEntities` | Array\<String\> | Relationship targets from entity's known relationships. |

**Context Richness by Mode**:

| Mode | Available Fields |
|------|------------------|
| Session | All fields populated from file intelligence, parsed entities, workspace resolution. |
| Selection | `sourceApp` only. All structural fields are null. |
| Screenshot | `sourceApp` only. All structural fields are null. |
| Follow-up | Inherits context from the original explanation. |

**Factory Method**: `minimal(sourceApp)` creates a context with only `sourceApp` set, used for Selection and Screenshot modes.

### 4.6 InvestigationAnchor

**Purpose**: Accumulated structural knowledge about what an investigation covers. Used for boundary detection and topic switching.

**Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `filePaths` | Set\<String\> | Primary file paths involved. |
| `entityNames` | Set\<String\> | Entity qualified names encountered. |
| `moduleNames` | Set\<String\> | Module names touched. |
| `workspaceID` | UUID? | Associated workspace. |
| `layers` | Set\<String\> | Architectural layers touched. |
| `relatedEntityNames` | Set\<String\> | Entities encountered as call/conformance/inheritance targets. |

**Methods**:
- `absorb(context: InsightContext)`: Merges all non-null fields from the context into this anchor. Set operations are additive (union). `workspaceID` is overwritten (last wins).
- `isEmpty`: Returns `true` if `filePaths`, `entityNames`, and `moduleNames` are all empty.

**Factory**: `empty` creates an anchor with all sets empty and `workspaceID` null.

### 4.7 KnowledgeSentence

**Purpose**: A single sentence within knowledge tracking (both Investigation `currentUnderstanding` and Working Memory), with metadata for the knowledge evolution algorithm.

**Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `text` | String | The knowledge sentence text. |
| `reinforcementCount` | Int | How many times a later insight matched this sentence but did not replace it. Higher = more foundational, harder to evict. |

### 4.8 WorkingMemory

**Purpose**: A continuously evolving, bounded understanding of the current investigation topic, optimized for prompt injection.

**Fields**:

| Field | Type | Description |
|-------|------|-------------|
| `content` | String | Synthesized understanding text, ready for prompt injection. |
| `sentences` | Array\<KnowledgeSentence\> | Sentence-level tracking for evolution algorithm. |
| `anchor` | InvestigationAnchor | Structural anchor for topic boundary detection. |
| `compressionCount` | Int | Number of times this WM has been LLM-compressed. Diagnostics only. |
| `topicKeywords` | Array\<String\> | Accumulated topic keywords for semantic switching. FIFO eviction. |

**Constants**:

| Constant | Value | Purpose |
|----------|-------|---------|
| `maxTopicKeywords` | 40 | Maximum keywords retained. Oldest evicted first (FIFO). |
| `maxContentCharacters` | 1000 | Hard limit before compression is triggered. |
| `compressionTargetCharacters` | 250 | Target after LLM compression. |

**Factory**: `empty(anchoredTo: context)` creates a Working Memory with empty content, no sentences, no keywords, zero compression count, and an anchor initialized from the given context.

---

## 5. Working Memory

### 5.1 Purpose

Working Memory is the operational knowledge layer of Virtual Session. It answers a single question: "What does the LLM need to know about the user's current investigation right now?"

Unlike Investigations (which organize knowledge by structural scope and preserve it indefinitely), Working Memory is:
- **Singular**: one per session.
- **Temporal**: represents the current state of the user's investigation, not its history.
- **Bounded**: hard character limit with compression.
- **Topic-scoped**: resets when the user changes topics.
- **Unconditional**: always injected when non-empty.

### 5.2 Lifecycle

```
                          Session starts
                               |
                               v
                    +-------------------+
                    | Working Memory    |
                    | = null            |
                    +-------------------+
                               |
                    First insight recorded
                               |
                               v
                    +-------------------+
                    | Working Memory    |
                    | initialized       |
                    | from first insight|
                    +-------------------+
                               |
                    +----------+-----------+
                    |                      |
            Same topic?              Topic switch?
                    |                      |
                    v                      v
            +-------------+      +-------------------+
            | Evolve:     |      | Reset:            |
            | - dedup     |      | - new content     |
            | - replace   |      | - new anchor      |
            | - append    |      | - new keywords    |
            | - evict     |      | - compressionCount|
            +-------------+      |   preserved?  NO  |
                    |            +-------------------+
                    v                      |
            Over 1000 chars?              v
            +---+-----+          (return to "initialized")
            |         |
          Yes        No
            |         |
            v         v
      Trigger       Save
      compression
            |
            v
      +------------------+
      | Async LLM call   |
      | or deterministic  |
      | fallback          |
      +------------------+
            |
            v
      Working Memory
      compressed to ~250
```

#### 5.2.1 Initialization

Working Memory is initialized on the **first insight** after a session is created or after a topic switch. Initialization:

1. Creates an empty anchor and absorbs the insight's context.
2. Decomposes the insight's understanding into sentences.
3. Creates KnowledgeSentences with `reinforcementCount = 0` for each sentence.
4. Joins sentences with newline separators to form `content`.
5. Extracts topic keywords from the understanding.

#### 5.2.2 Evolution (Same Topic)

When a new insight arrives and no topic switch is detected:

1. **Absorb context**: the new insight's context is absorbed into the Working Memory anchor.
2. **Sentence-level evolution**: each sentence from the new understanding is integrated using the Knowledge Evolution Algorithm (Section 5.4).
3. **Keyword accumulation**: new topic keywords are extracted and appended (duplicates skipped, FIFO eviction at 40).
4. **Deterministic eviction**: sentences are evicted if total content exceeds 1000 characters.
5. **Content reconstruction**: remaining sentences joined with newlines.
6. **Compression trigger**: if content still exceeds 1000 characters after eviction, async compression is triggered.

#### 5.2.3 Topic Switch (Reset)

When a topic switch is detected (see Section 7), Working Memory is **reset**:

1. A new empty Working Memory is created, anchored to the new insight's context.
2. The new understanding's sentences become the initial content.
3. Topic keywords are extracted from the new understanding.
4. `compressionCount` is reset to 0.
5. All prior Working Memory content is discarded.

Working Memory resets are **independent** of investigation management. A topic switch may or may not coincide with a new investigation being created, depending on the structural affinity scoring.

#### 5.2.4 Compression

When content exceeds 1000 characters and cannot be brought under the limit by deterministic eviction alone, async LLM compression is triggered. See Section 8 for the complete compression specification.

### 5.3 Prompt Injection

Working Memory injection is unconditional and parameter-free. The `workingMemoryBlock()` method:

1. Returns `null` if no active session.
2. Returns `null` if Working Memory is `null`.
3. Returns `null` if content is empty or whitespace-only.
4. Otherwise, returns the formatted prompt block:

```
WORKING MEMORY (your evolving understanding from this session):
{content}
Build on this understanding. Do not repeat it.
```

No scoring. No threshold. No context parameter. If Working Memory has content, it is injected.

### 5.4 Knowledge Evolution Algorithm

The Knowledge Evolution Algorithm integrates new knowledge sentences into an existing set of KnowledgeSentences. It is used identically by both Working Memory and Investigation knowledge.

**For each new sentence (candidate):**

1. Compute `candidateScore = informationScore(candidate)` (count of meaningful non-stop-words).
2. Find the best matching existing sentence:
   - For each existing sentence, compute `wordOverlap(candidate, existing)`.
   - Keep the existing sentence with the highest overlap that exceeds `sentenceOverlapThreshold` (0.6).
3. If a match is found:
   - Compute `existingScore = informationScore(existingSentence)`.
   - If `candidateScore > existingScore`: **replace** the existing sentence with the candidate. Reset `reinforcementCount` to 0.
   - Otherwise: **reinforce** the existing sentence. Increment `reinforcementCount` by 1.
4. If no match is found: **append** the candidate as a new KnowledgeSentence with `reinforcementCount = 0`.

**After all candidates are integrated:**

5. **Evict** least-important sentences until total character count (including newline separators) fits within the character budget.

### 5.5 Character Budget

Working Memory has a **hard limit** of 1000 characters (`maxContentCharacters`). Character count includes:
- The text of each sentence.
- Newline separators between sentences (one fewer than sentence count).

After sentence-level evolution, deterministic eviction removes the least-important sentence repeatedly until content fits. If content still exceeds 1000 characters (theoretically possible if a single sentence is longer than 1000 characters), async compression is triggered.

### 5.6 Topic Keyword Management

Topic keywords are accumulated across insights to support semantic topic switching for Selection and Screenshot modes (where no structural context is available).

**Extraction** (`extractTopicKeywords`):
1. Lowercase the understanding text.
2. Split on non-alphanumeric characters.
3. Filter out: empty strings, words with fewer than 3 characters, all-numeric words, words in `topicStopWords`.
4. Deduplicate, preserving order of first appearance.

**Accumulation**:
- New keywords are appended if not already present.
- When count exceeds `maxTopicKeywords` (40), the oldest keywords are removed first (FIFO).

**Topic Stop Words** (`topicStopWords`):
A superset of the base `stopWords` used for information density scoring. Includes programming-generic terms that carry no topic signal:

Base stop words (50):
```
the, a, an, is, are, was, were, in, on, to, of, for, and, or, by, with, that, this, it,
from, as, at, be, has, have, had, not, but, its, also, can, will, does, do, if, when,
which, each, all, into, than, then, been, being, so, no, only, very, just
```

Programming-generic additions (77):
```
function, method, class, struct, enum, protocol, type, variable, property, parameter,
argument, return, returns, value, object, instance, static, private, public, internal,
import, module, file, code, line, call, calls, called, uses, used, using, use, handles,
handle, handled, creates, create, created, provides, provide, takes, given, passed,
defined, defines, implements, implementation, pattern, data, string, int, bool, array,
dictionary, set, list, map, key, error, nil, null, true, false, self, super, new, default,
custom, specific, based, main, first, multiple, single, when, where, how, what, like,
through, between, within, across, any, other, some
```

### 5.7 Failure Handling

Working Memory evolution is entirely deterministic except for compression. If the AI provider is unavailable:
- Compression falls back to deterministic eviction.
- All other Working Memory operations (initialization, evolution, topic switching, keyword extraction) proceed normally.

Working Memory operations never throw exceptions. Persistence failures are logged but do not halt evolution.

### 5.8 Concurrency

Working Memory is owned by the VirtualSessionManager, which is isolated to the main thread (see Section 14). All Working Memory mutations happen on the main thread. The only concurrent operation is the async compression task, which reads Working Memory content, sends it to the LLM off the main thread, then applies the result back on the main thread.

---

## 6. Investigations

### 6.1 Purpose

Investigations are the archival knowledge layer of Virtual Session. They organize insights by structural scope (file, entity, module) and maintain a synthesized understanding that evolves as new insights join.

While Working Memory tracks "what the LLM needs to know right now," investigations track "what the user has learned during this session, organized by topic."

### 6.2 Lifecycle

#### 6.2.1 Creation

An investigation is created when:
- The session has no investigations (first insight).
- The active investigation has low structural affinity with the new insight (see Section 6.4).

Creation involves:
1. Creating an empty InvestigationAnchor and absorbing the new context.
2. Building an initial theme from the context.
3. Decomposing the understanding into KnowledgeSentences.
4. Initializing `currentUnderstanding` from the decomposed sentences.
5. Initializing `knownFiles` from `fileName` and `knownEntities` from `entityName` + `relatedEntities`.

#### 6.2.2 Theme Building

**Initial theme** (priority order):
1. If `fileName` is available: `"Understanding {fileName}"`.
2. If `entityName` is available: `"Understanding {entityName}"`.
3. If `sourceApp` is available: `"Investigating code in {sourceApp}"`.
4. Fallback: `"Code investigation"`.

**Theme updates** (when scope expands):
- If 3+ modules in anchor: `"Architectural investigation across {module1}, {module2}, {module3}"`.
- If 2+ files with a module: `"Investigating {moduleName} relationships"`.
- If 2+ files without a module: `"Cross-file investigation"`.
- Single-file investigations keep their initial theme.

#### 6.2.3 Growth (Appending Insights)

When an insight continues the active investigation:
1. Append the insight to the investigation's insight array.
2. Absorb the insight's context into the investigation's anchor.
3. Evolve the investigation's knowledge using the Knowledge Evolution Algorithm (Section 5.4) with a budget of 600 characters (`maxUnderstandingCharacters`).
4. Accumulate `knownFiles` (from `fileName`) and `knownEntities` (from `entityName` + `relatedEntities`).
5. Update the theme if the investigation scope has expanded.

#### 6.2.4 Knowledge Evolution

Investigation knowledge evolution uses the same algorithm as Working Memory evolution (Section 5.4), but with a different budget:
- Working Memory budget: 1000 characters.
- Investigation knowledge budget: 600 characters (`maxUnderstandingCharacters`).

After evolution, `currentUnderstanding` is reconstructed by joining KnowledgeSentence texts with newlines.

#### 6.2.5 Eviction

Investigations are evicted under three conditions (enforced after every insight recording):
1. Investigation count exceeds `maxInvestigationCount` (5): oldest investigation removed.
2. Total insight count exceeds `maxInsightCount` (20): oldest insights from oldest investigation removed. Empty investigations cleaned up.
3. Total character count exceeds `maxTotalCharacters` (3000): oldest insights from oldest investigation removed. Empty investigations cleaned up.

Eviction is always FIFO (oldest first) at the investigation level, and FIFO within each investigation.

### 6.3 Relationship with Working Memory

Investigations and Working Memory evolve in parallel from the same insight stream. They are structurally independent:

- A new investigation does NOT reset Working Memory (unless the topic switch detection also triggers).
- A Working Memory reset does NOT create a new investigation (unless the investigation boundary detection also triggers).
- Topic switching and investigation boundary detection use similar but not identical logic (see Section 7).

### 6.4 Investigation Boundary Detection

The `shouldStartNewInvestigation(newContext)` algorithm determines whether a new insight should continue the active investigation or start a new one.

**Algorithm** (evaluated in order, returns on first match):

| Step | Condition | Result |
|------|-----------|--------|
| 1 | No active investigation exists | Start new |
| 2 | Active investigation anchor is empty | Start new |
| 3 | New context's `filePath` matches any anchor `filePath` | Continue |
| 4 | New context's `entityName` matches any anchor `entityName` | Continue |
| 5 | New context's `entityName` is in anchor's `relatedEntityNames` | Continue |
| 6 | Any of new context's `relatedEntities` is in anchor's `entityNames` | Continue |
| 7 | Module AND layer overlap (both match) | Continue |
| 8 | Module overlap with anchor having >2 entities | Continue |
| 9 | None of the above | Start new |

**Design rationale**: The algorithm is deliberately permissive — it errs on the side of continuing an investigation rather than fragmenting it. File overlap is the strongest signal (any shared file means the investigation continues). Entity relationships are the next strongest signal. Module+layer overlap catches cases where the user explores different parts of the same architectural layer.

### 6.5 Retrieval API

The retrieval API is used by the legacy `formatInsightBlock(for: context)` method. It is distinct from Working Memory injection and provides investigation-level or insight-level knowledge for prompt augmentation.

#### 6.5.1 Best Matching Investigation

For each investigation, compute the maximum affinity score across its insights. Return the investigation with the highest max score, if it exceeds `minimumRetrievalScore` (0.2).

#### 6.5.2 Investigation-Level Retrieval (Preferred)

If the best matching investigation has a non-empty `currentUnderstanding`, use it directly:

```
INVESTIGATION CONTEXT (from earlier in this session):
{currentUnderstanding}
Build on this understanding. Do not repeat it.
```

#### 6.5.3 Insight-Level Retrieval (Legacy Fallback)

If no investigation has `currentUnderstanding`, fall back to individual insight retrieval:

1. Score all insights using `affinityScore(query, insight.context)`.
2. Filter by `minimumRetrievalScore` (0.2).
3. Sort by score descending, then by recency (most recent first for ties).
4. Apply character budget (`maxInsightBlockCharacters` = 800): include insights until budget would be exceeded. Allow the first insight to exceed the budget.

Format:
```
INVESTIGATION CONTEXT (from earlier in this session):
- {insight1.understanding}
- {insight2.understanding}
Build on these insights. Do not repeat them.
```

### 6.6 Affinity Score Computation

The `affinityScore(query, insight)` function computes structural similarity between two InsightContexts. Scores are additive and capped at 1.0.

| Component | Score | Condition |
|-----------|-------|-----------|
| File path match | +0.50 | `query.filePath == insight.filePath` (both non-null) |
| Entity name match | +0.30 | `query.entityName == insight.entityName` (both non-null) |
| Related entity overlap (direct) | +0.20 | `query.entityName` appears in `insight.relatedEntities`, or vice versa |
| Related entity set overlap | +0.15 | Any overlap between `query.relatedEntities` and `insight.relatedEntities` (only if direct overlap didn't match) |
| Module + layer match | +0.15 | Both `moduleName` and `layer` match |
| Module-only match | +0.10 | `moduleName` matches but `layer` doesn't (or layer is null) |
| Same source app | +0.05 | `query.sourceApp == insight.sourceApp` (weak signal for Selection/Screenshot) |

**Note**: Related entity scoring has three tiers that are mutually exclusive. The direct overlap (+0.20) is checked first. If neither direct match fires, set overlap (+0.15) is checked. Only one of the three fires.

---

## 7. Topic Switching

### 7.1 Why Topic Switching Exists

Without topic switching, Working Memory would accumulate all knowledge from the entire session, regardless of topic. If a user investigates authentication for 30 minutes and then switches to database indexing, the authentication knowledge would be injected into every database prompt, wasting context and potentially confusing the LLM.

Topic switching detects when the user has changed subjects and resets Working Memory to start fresh.

### 7.2 Two-Layer Detection

Topic switching uses two independent detection layers. The appropriate layer is selected based on the available context data.

#### 7.2.1 Layer 1: Structural Switching (Session Mode)

Used when the new insight context has structural fields: `filePath`, `entityName`, or `moduleName`.

This layer reuses the same anchor-based comparison as investigation boundary detection, but checks against the Working Memory anchor instead of the active investigation anchor.

**Algorithm** (evaluated in order):

| Step | Condition | Result |
|------|-----------|--------|
| 1 | No existing Working Memory | No switch (will initialize) |
| 2 | Working Memory anchor is empty | No switch |
| 3 | New `filePath` in WM anchor's `filePaths` | No switch |
| 4 | New `entityName` in WM anchor's `entityNames` | No switch |
| 5 | New `entityName` in WM anchor's `relatedEntityNames` | No switch |
| 6 | Any new `relatedEntity` in WM anchor's `entityNames` | No switch |
| 7 | Module AND layer overlap | No switch |
| 8 | Module overlap with anchor having >2 entities | No switch |
| 9 | None of the above | **Switch** |

#### 7.2.2 Layer 2: Semantic Switching (Selection/Screenshot Mode)

Used when the new insight context has no structural fields (Selection and Screenshot modes provide only `sourceApp`).

This layer compares topic keywords between the new understanding and the existing Working Memory.

**Algorithm**:

1. If Working Memory has no topic keywords: no switch.
2. Extract topic keywords from the new understanding.
3. If fewer than 2 keywords extracted: no switch (insufficient evidence to judge).
4. Compute overlap: how many of the new keywords exist in Working Memory's keywords.
5. If overlap is **zero** (no shared keywords): **switch**.
6. Otherwise: no switch.

**Design rationale**: Requiring zero overlap is deliberately conservative. Even a single shared keyword indicates possible topic continuity. The >=2 keyword evidence threshold prevents short, generic understandings from triggering spurious switches.

### 7.3 Examples

#### Example 1: No Switch (Related Subtopics)

```
Insight 1: "JWT authentication validates token signatures using HMAC-SHA256"
  Keywords: [jwt, authentication, validates, token, signatures, hmac, sha256]

Insight 2: "Token authentication also checks issuer and audience claims"
  Keywords: [token, authentication, checks, issuer, audience, claims]

  Overlap: [token, authentication] (2 keywords)
  Decision: NO SWITCH (overlap > 0)
```

#### Example 2: Switch (Unrelated Topics)

```
Working Memory keywords: [jwt, authentication, validates, token, signatures, hmac, sha256]

New understanding: "SQL query optimization uses index scans for range predicates"
  Keywords: [sql, query, optimization, index, scans, range, predicates]

  Overlap: [] (0 keywords)
  Evidence words: 7 (>= 2)
  Decision: SWITCH
```

#### Example 3: No Switch (Structural Continuity in Session Mode)

```
Working Memory anchor: filePaths = {"/src/Auth.swift"}, entityNames = {"Auth.validate"}

New context: filePath = "/src/Auth.swift", entityName = "Auth.refreshToken"

  Step 3: filePath "/src/Auth.swift" found in anchor → NO SWITCH
```

#### Example 4: Switch (Different File/Module in Session Mode)

```
Working Memory anchor: filePaths = {"/src/Auth.swift"}, entityNames = {"Auth.validate"},
                       moduleNames = {"Authentication"}, layers = {"application"}

New context: filePath = "/src/Database.swift", entityName = "Database.query",
             moduleName = "Storage", layer = "infrastructure"

  Step 3: filePath not found
  Step 4: entityName not found
  Step 5: entityName not in relatedEntityNames
  Step 6: no related entity overlap
  Step 7: module "Storage" != "Authentication" → no module overlap
  Step 9: SWITCH
```

### 7.4 Edge Cases

**Short understandings (1 keyword)**: Not enough evidence to determine topic. No switch triggered. This prevents generic explanations like "This handles errors" from resetting Working Memory.

**Empty Working Memory keywords**: Cannot compare. No switch triggered. The first few insights always build Working Memory rather than resetting it.

**Aggressive switching in Selection Mode**: Because Selection Mode provides only `sourceApp`, topic switching relies entirely on keyword overlap. Two genuinely related subtopics with no shared keywords will trigger a switch. This is a known tradeoff — it is better to occasionally reset Working Memory (losing some context) than to inject irrelevant context (confusing the LLM). Example:

```
"Authentication uses OAuth 2.0 bearer tokens"  →  keywords: [authentication, oauth, bearer, tokens]
"Keychain stores encrypted credentials"         →  keywords: [keychain, stores, encrypted, credentials]

Overlap: 0 → SWITCH (even though both relate to auth)
```

This is accepted because the Working Memory would contain only a few sentences, and losing them is low-cost compared to the risk of injecting authentication context into a database explanation.

### 7.5 Topic Switching vs Investigation Boundary Detection

Topic switching and investigation boundary detection are related but independent:

| Aspect | Investigation Boundary | Topic Switching |
|--------|----------------------|-----------------|
| What is compared | Anchor of active investigation | Anchor of Working Memory |
| When | Always, for every insight | Only for Working Memory evolution |
| Structural layer | Same algorithm | Same algorithm |
| Semantic layer | N/A (investigations only use structure) | Topic keyword comparison |
| Effect | Creates new investigation | Resets Working Memory |

A single insight can trigger both (new investigation AND Working Memory reset), either one independently, or neither.

---

## 8. Compression

### 8.1 Why Compression Exists

Working Memory evolves by integrating new sentences. As the user asks more questions about the same topic, Working Memory grows. Without compression, it would eventually consume too many tokens in the system prompt, degrading explanation quality and increasing cost.

Compression reduces Working Memory to a dense summary while preserving key technical facts, entity names, and relationships.

### 8.2 When Compression Triggers

Compression is triggered when Working Memory content exceeds `maxContentCharacters` (1000) **after** deterministic eviction has been applied. This means compression only fires when eviction alone cannot bring content under the limit (typically because there are few sentences, each individually long, or a single very long sentence).

### 8.3 Compression Workflow

```
evolveWorkingMemory()
    |
    v
Sentence-level evolution
    |
    v
Deterministic eviction (budget: 1000)
    |
    v
Reconstruct content
    |
    v
content.count > 1000?
    |
  Yes → triggerCompression()
    |
    v
Cancel any in-flight compression task
    |
    v
Spawn new async task: performCompression()
    |
    +--→ Get AI provider
    |       |
    |     null?
    |       |
    |     Yes → deterministicCompress() → done
    |       |
    |      No ↓
    |    Send LLM prompt
    |       |
    |    Response valid?
    |    (30–250 chars)
    |       |
    |     No → deterministicCompress() → done
    |       |
    |    Yes ↓
    |    Session still active?
    |       |
    |     No → done (discard result)
    |       |
    |    Yes ↓
    |    Apply compressed content
    |    Decompose into new sentences
    |    Reset reinforcement counts
    |    Increment compressionCount
    |    Save
```

### 8.4 LLM Compression Prompt

```
System: You are a precise technical summarizer. Output only the compressed summary.

User: Compress the following working memory into a dense summary under {compressionTargetCharacters}
characters. Preserve all key technical facts, entity names, and relationships. Remove filler and
redundancy. Output ONLY the compressed summary, no preamble.

Working memory:
{content}
```

The AI mode parameter is `"compression"`.

### 8.5 Response Validation

The LLM response is validated before being applied:
- Trimmed of whitespace and newlines.
- Must be at least 30 characters (too short suggests the LLM produced a trivial summary).
- Must be at most `compressionTargetCharacters` (250) characters (must actually be compressed).
- If validation fails, fall back to deterministic compression.

### 8.6 Deterministic Compression

Deterministic compression is the fallback when LLM compression fails or is unavailable. It uses the same importance-scored eviction as the Knowledge Evolution Algorithm:

1. While total character count exceeds `compressionTargetCharacters` (250) and more than 1 sentence remains:
   a. Find the sentence with the lowest importance score.
   b. Remove it.
2. Reconstruct content from remaining sentences.
3. Increment `compressionCount`.
4. Save.

### 8.7 Importance Score Formula

```
importanceScore(sentence, isLast) =
    informationScore(sentence.text) × 0.5
  + sentence.reinforcementCount × 2.0
  + (isLast ? 1.0 : 0.0)
```

Where:
- `informationScore(text)` = count of meaningful (non-stop-word) words.
- `reinforcementCount` = how many times this sentence was reinforced (matched by a new sentence but not replaced because the existing sentence was richer).
- `isLast` = whether this is the last sentence in the array (most recently added/modified).

**Scoring rationale**:
- Dense sentences (more meaningful words) carry more knowledge.
- Reinforced sentences have been validated by multiple insights.
- Recent sentences should be preserved because the user is currently thinking about them.
- The 2.0 multiplier on reinforcement makes validated knowledge significantly harder to evict.

### 8.8 Cancellation

Only one compression task runs at a time. When a new compression is triggered:
1. The previous compression task (if any) is cancelled.
2. A new task is spawned.

Cancellation is also performed when:
- The session ends (`endSession()`).
- The session expires (`expireIfNeeded()`).

After cancellation, the compression task checks whether the session is still active before applying results. If the session has ended or been replaced, the compressed result is silently discarded.

### 8.9 Concurrency

Compression runs as an async task on the main actor. The LLM call itself runs asynchronously (the AI provider handles threading internally). When the LLM call completes, the result is applied back on the main thread.

The critical invariant is: compression reads the Working Memory content snapshot before the LLM call, and checks that the session is still active after. Between the read and the write, other mutations may have occurred (new insights, new Working Memory evolution). The compression result replaces the Working Memory content entirely — this is acceptable because compression preserves the same information in fewer characters.

---

## 9. Prompt Augmentation

### 9.1 Injection Point

Working Memory is injected into the **system prompt** of the explanation request. It is appended to the end of the system prompt string with a double-newline separator:

```
{existing system prompt}\n\n{workingMemoryBlock}
```

### 9.2 Injection Timing

Injection happens **before** the LLM call. In the coordinator flow:

1. Coordinator builds the system prompt (explanation framework, context tier, file intelligence).
2. Coordinator checks if Virtual Session is enabled.
3. If enabled, calls `workingMemoryBlock()`.
4. If the block is non-null, appends it to the system prompt.
5. Coordinator sends the system prompt to the LLM.

### 9.3 Injection Format

```
WORKING MEMORY (your evolving understanding from this session):
{content}
Build on this understanding. Do not repeat it.
```

The header "WORKING MEMORY" is intentionally prominent to help the LLM distinguish session context from other system prompt content. The instruction "Build on this understanding. Do not repeat it." guides the LLM to treat the Working Memory as established knowledge and produce explanations that extend it rather than restate it.

### 9.4 Conditional Logic

The injection is gated by exactly two conditions:
1. Virtual Session must be enabled (`isEnabled` reads from user preferences).
2. `workingMemoryBlock()` must return non-null (which requires an active session with non-empty Working Memory).

There is **no** relevance scoring, no context matching, no threshold. If Working Memory has content, it is injected. This unconditional approach prevents false negatives (failing to inject relevant context) at the cost of occasionally injecting slightly off-topic context. The topic switching system mitigates this cost.

### 9.5 Token Considerations

Working Memory content is bounded at 1000 characters before compression, and compressed to approximately 250 characters. At a conservative 4 characters per token, this represents approximately 60-250 tokens added to the system prompt. This is negligible compared to the typical system prompt size (2000-5000 tokens for the explanation framework, context tier, and file intelligence).

### 9.6 Interaction with Pipeline Path

In Session Mode, the coordinator may use either the legacy path or the pipeline path. Working Memory injection is the same in both paths: it is appended to the system prompt at the coordinator level, before the path diverges.

The pipeline's reasoning engines (ExplainReasoningEngine, etc.) are frozen pipeline modules and do NOT receive Working Memory directly. Working Memory reaches them only through the system prompt that the coordinator passes to the pipeline.

**Note**: In the current implementation, only the legacy path injects Working Memory into the system prompt. The pipeline path does not inject Working Memory because the pipeline constructs its own prompts internally. This is a known limitation, not a design decision. The pipeline path still records insights that evolve Working Memory.

### 9.7 Interaction with Follow-up Mode

Follow-up questions use a dedicated follow-up system prompt, not the explanation system prompt. Working Memory injection applies to follow-up prompts in the same way — the coordinator appends it to whatever system prompt is being used.

---

## 10. Explanation Lifecycle

### 10.1 Complete Lifecycle (Selection Mode)

The simplest lifecycle — no file intelligence, no workspace resolution.

```
User double-taps Control
       |
       v
SelectionModeCoordinator captures selected text
       |
       v
Build system prompt (ExplanationFramework V7 or DSA)
       |
       v
Is Virtual Session enabled?
       |
     Yes → workingMemoryBlock() → append to system prompt (if non-null)
       |
       v
Send to LLM (streaming)
       |
       v
Display explanation in HUD
       |
       v
Stream completes → onComplete callback fires
       |
       v
Is Virtual Session enabled?
       |
     No → done
       |
     Yes ↓
       |
extractUnderstanding(from: explanationText, sourceApp: sourceAppName)
       |
       v
Create InsightContext.minimal(sourceApp: sourceAppName)
       |
       v
recordInsight(understanding, mode: .selection, context)
       |
       v
Inside recordInsight:
  |
  ├── Investigation routing (boundary detection)
  │     ├── Continue active investigation (append, evolve knowledge)
  │     └── Start new investigation (create, initialize knowledge)
  │
  ├── evolveWorkingMemory(understanding, context)
  │     ├── Topic switch? → Reset Working Memory
  │     ├── First insight? → Initialize Working Memory
  │     └── Same topic? → Evolve (dedup, replace, append, evict)
  │           └── Over 1000 chars? → triggerCompression()
  │
  ├── enforceStorageLimits()
  │     ├── Investigation count > 5 → evict oldest
  │     ├── Insight count > 20 → evict oldest insights
  │     └── Character count > 3000 → evict oldest insights
  │
  └── save() → write JSON to disk
```

### 10.2 Complete Lifecycle (Session Mode)

More complex — includes file intelligence, workspace resolution, entity matching.

```
User presses ⌃⇧O (file) or ⌃⇧P (directory), then double-taps Shift
       |
       v
SessionQuestionCoordinator captures snippet text
       |
       v
Resolve workspace → determine effective file/entities
       |
       v
Build rich InsightContext:
  - filePath, fileName from resolved file
  - entityName from entity matching
  - moduleName from directory structure
  - layer from file identity classification
  - fileRole from file identity
  - language from parser
  - workspaceID from workspace
  - relatedEntities from file intelligence relationships
       |
       v
Build system prompt (ExplanationFramework + context tier + file intelligence)
       |
       v
Is Virtual Session enabled?
       |
     Yes → workingMemoryBlock() → append to system prompt (if non-null)
       |
       v
Send to LLM (streaming) — legacy or pipeline path
       |
       v
Display explanation in HUD
       |
       v
Stream completes → onComplete callback fires
       |
       v
Is Virtual Session enabled?
       |
     No → done
       |
     Yes ↓
       |
extractUnderstanding(from: explanationText, sourceApp: sourceAppName)
       |
       v
recordInsight(understanding, mode: .session, context: richInsightContext)
       |
       (same recordInsight flow as Selection Mode)
```

### 10.3 Sequence Diagram

```
Coordinator          VirtualSessionManager      LLM        HUD       Disk
    |                        |                   |          |          |
    |--workingMemoryBlock()→ |                   |          |          |
    |←-- wmBlock ----------- |                   |          |          |
    |                        |                   |          |          |
    |-- append WM to system prompt              |          |          |
    |                        |                   |          |          |
    |-- stream request ------|--→ generate ---→  |          |          |
    |                        |                   |          |          |
    |                        |   ← streaming ----+→ show → |          |
    |                        |                   |          |          |
    |                        |        stream complete       |          |
    |                        |                   |          |          |
    |-- extractUnderstanding(explanationText) ---|----------|          |
    |← understanding         |                   |          |          |
    |                        |                   |          |          |
    |-- recordInsight(understanding, mode, ctx)→ |          |          |
    |                        |                   |          |          |
    |                        |-- route to investigation     |          |
    |                        |-- evolve investigation knowledge        |
    |                        |-- evolve working memory      |          |
    |                        |-- enforce limits             |          |
    |                        |-- save() ---------|----------|--→ write |
    |                        |                   |          |          |
    |                        |   [if WM > 1000 chars]       |          |
    |                        |-- triggerCompression()        |          |
    |                        |      |                        |          |
    |                        |      |--→ LLM compress -----→|          |
    |                        |      |←-- compressed text ----|          |
    |                        |      |                        |          |
    |                        |-- apply compressed WM         |          |
    |                        |-- save() ---------|----------|--→ write |
```

---

## 11. Memory Inspector

### 11.1 Purpose

The Memory Inspector is a debug and transparency tool that shows the user exactly what Virtual Session remembers. It serves two audiences:

- **Users**: understand what context is being injected into their explanations.
- **Developers**: debug and verify Virtual Session behavior during development.

### 11.2 Display Structure

The Memory Inspector is presented as a popover from the "View Memory" button in the settings area.

**Layout** (top to bottom):

1. **Header**: icon + "Virtual Session Memory" title.
2. **Statistics Section**: three stat badges showing:
   - Investigation count (numeric).
   - Insight count (total across all investigations).
   - Memory size (total character count, formatted as "N chars" or "N.NK").
3. **Working Memory Section** (shown only when Working Memory exists and has content):
   - Header with icon, "Working Memory" label, compression count (if >0), character count.
   - Content text (limited to 8 visible lines).
   - Topic keywords (last 10 shown, comma-separated, limited to 2 lines).
4. **Investigations Section**: each investigation displayed as a card, newest first:
   - Active indicator (dot) for the most recent investigation.
   - Theme (1 line).
   - Evidence count badge (e.g., "3 evidence").
   - Current understanding (6 lines max), or fallback to raw insight list for legacy investigations.
   - Known files (sorted list).
   - Known entities (sorted, max 5 shown).
5. **Empty State**: shown when no active session. Icon + "No active session" + hint text.
6. **Actions Bar**: "Clear Session" button (ends and restarts session).

### 11.3 Statistics

| Statistic | Source | Format |
|-----------|--------|--------|
| Investigations | `session.investigations.count` | Integer |
| Insights | `session.totalInsightCount` | Integer |
| Memory | `session.totalCharacterCount` | `"N chars"` if <1000, `"N.NK"` if >=1000 |

### 11.4 Synchronization

The Memory Inspector reads directly from the VirtualSessionManager's `activeSession`. Because the manager is main-actor-isolated and the UI runs on the main thread, the inspector always sees the latest state without synchronization primitives.

The inspector does not modify Virtual Session state (except via the "Clear Session" button, which calls `endSession()` followed by `startSession()`).

### 11.5 Fixed Dimensions

- Width: 360 points.
- Height: minimum 200 points, maximum 500 points.
- Scrollable content area between header and actions bar.

---

## 12. Persistence

### 12.1 Storage Format

Virtual Session is persisted as a single JSON file.

**Default path**: `{application support directory}/Decode/virtual-session.json`

Platform-specific application support directories:
- macOS: `~/Library/Application Support/Decode/`
- Windows: `%APPDATA%/Decode/`
- Linux: `~/.local/share/Decode/`

### 12.2 Serialization

**Encoding**:
- Format: JSON.
- Date encoding: ISO8601.
- Output formatting: Pretty-printed, sorted keys (for human readability and diff stability).
- Write mode: Atomic (write to temp file, then rename — prevents partial writes on crash).

**Decoding**:
- Date decoding: ISO8601.
- Error handling: returns null on any decode error (corrupt or incompatible file).

### 12.3 When Persistence Occurs

The session is saved to disk after every mutation:
- `startSession()` — after creating the new session.
- `recordInsight()` — after all investigation/WM updates and limit enforcement.
- `evolveWorkingMemory()` — after WM initialization, evolution, or topic switch.
- `performCompression()` — after applying compressed content.
- `deterministicCompress()` — after deterministic eviction.

This incremental persistence ensures that unexpected termination loses at most the current in-flight operation.

### 12.4 When Persistence File is Deleted

The persistence file is deleted when:
- `endSession()` is called.
- `expireIfNeeded()` finds an expired session.
- `restore()` finds the toggle is disabled but a persisted file exists.

### 12.5 Loading

Loading reads the file, decodes JSON, and returns null on any error (file missing, unreadable, corrupt JSON, incompatible schema).

### 12.6 Restoration Flow

`restore()` is called during app startup (deferred startup phase):

1. Check if Virtual Session toggle is enabled (user preferences).
   - If disabled: delete any persisted file, set session to null. **Done.**
2. Attempt to load the persisted session file.
   - If load fails (no file): start a fresh session. **Done.**
3. Set the loaded session as active.
4. Check expiration.
   - If expired: delete persisted file, start a fresh session. **Done.**
5. Session restored successfully.

### 12.7 Backward Compatibility

The `workingMemory` field on VirtualSession is optional (nullable). Sessions persisted before Working Memory was implemented will deserialize with `workingMemory = null`. The first insight recorded will initialize Working Memory.

Similarly, `currentUnderstanding`, `knowledgeSentences`, `knownFiles`, and `knownEntities` on Investigation are all optional. Legacy investigations will display raw insights in the Memory Inspector instead of synthesized knowledge.

### 12.8 Migration Strategy

No explicit migration is needed. All new fields are optional with null defaults. The system bootstraps them from null on the first insight after loading.

If a future schema change requires breaking compatibility, the load function will return null (decode error), and a fresh session will be started. This is acceptable because Virtual Sessions are ephemeral (2-hour lifetime).

### 12.9 Example JSON

```json
{
  "id": "E7A2F1B3-4C5D-6E7F-8A9B-0C1D2E3F4A5B",
  "startedAt": "2026-07-31T10:00:00Z",
  "workingMemory": {
    "content": "Auth validates JWT tokens using HMAC-SHA256.\nToken expiration is checked against server time with 5-minute clock skew tolerance.",
    "sentences": [
      {
        "text": "Auth validates JWT tokens using HMAC-SHA256.",
        "reinforcementCount": 2
      },
      {
        "text": "Token expiration is checked against server time with 5-minute clock skew tolerance.",
        "reinforcementCount": 0
      }
    ],
    "anchor": {
      "filePaths": ["/src/Auth.swift"],
      "entityNames": ["Auth.validate", "Auth.checkExpiration"],
      "moduleNames": ["Authentication"],
      "workspaceID": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
      "layers": ["application"],
      "relatedEntityNames": ["KeychainService.store", "TokenManager.refresh"]
    },
    "compressionCount": 0,
    "topicKeywords": ["auth", "validates", "jwt", "tokens", "hmac", "sha256", "expiration", "checked", "server", "clock", "skew", "tolerance"]
  },
  "investigations": [
    {
      "id": "B1C2D3E4-F5A6-7B8C-9D0E-F1A2B3C4D5E6",
      "startedAt": "2026-07-31T10:00:00Z",
      "theme": "Understanding Auth.swift",
      "insights": [
        {
          "id": "C1D2E3F4-A5B6-7C8D-9E0F-A1B2C3D4E5F6",
          "timestamp": "2026-07-31T10:05:00Z",
          "mode": "session",
          "understanding": "Auth validates JWT tokens using HMAC-SHA256 signatures with a configurable secret key",
          "context": {
            "filePath": "/src/Auth.swift",
            "fileName": "Auth.swift",
            "entityName": "Auth.validate",
            "entityType": "function",
            "moduleName": "Authentication",
            "layer": "application",
            "fileRole": "service",
            "language": "swift",
            "sourceApp": "Xcode",
            "workspaceID": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "relatedEntities": ["KeychainService.store", "TokenManager.refresh"]
          }
        }
      ],
      "anchor": {
        "filePaths": ["/src/Auth.swift"],
        "entityNames": ["Auth.validate"],
        "moduleNames": ["Authentication"],
        "workspaceID": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
        "layers": ["application"],
        "relatedEntityNames": ["KeychainService.store", "TokenManager.refresh"]
      },
      "currentUnderstanding": "Auth validates JWT tokens using HMAC-SHA256 signatures with a configurable secret key.",
      "knowledgeSentences": [
        {
          "text": "Auth validates JWT tokens using HMAC-SHA256 signatures with a configurable secret key.",
          "reinforcementCount": 0
        }
      ],
      "knownFiles": ["Auth.swift"],
      "knownEntities": ["Auth.validate", "KeychainService.store", "TokenManager.refresh"]
    }
  ]
}
```

---

## 13. State Machine

### 13.1 Session-Level States

```
                    ┌────────────┐
                    │   IDLE     │  No active session
                    └─────┬──────┘
                          │ User enables toggle
                          │ OR restore() with valid session
                          v
                    ┌────────────┐
                    │  CREATED   │  Empty session, no insights
                    └─────┬──────┘
                          │ First insight recorded
                          v
                    ┌────────────┐
            ┌──────→│  ACTIVE    │←──────┐
            │       └─────┬──────┘       │
            │             │              │
   Insight recorded   Inactivity     Compression
   (stays active)     > 2 hours      completes
            │             │              │
            │             v              │
            │       ┌────────────┐       │
            │       │  EXPIRED   │       │
            │       └─────┬──────┘       │
            │             │              │
            │             v              │
            │       ┌────────────┐       │
            └───────│   ENDED    │───────┘
                    └────────────┘
                          │ User re-enables toggle
                          v
                    ┌────────────┐
                    │  CREATED   │  (new session)
                    └────────────┘
```

### 13.2 State Transitions

| From | Event | To | Actions |
|------|-------|----|---------|
| IDLE | Toggle enabled | CREATED | Create VirtualSession, save to disk |
| IDLE | Restore with valid file | ACTIVE | Load from disk |
| IDLE | Restore with expired file | CREATED | Delete file, create new session |
| IDLE | Restore with toggle disabled | IDLE | Delete any leftover file |
| CREATED | `recordInsight()` | ACTIVE | Create investigation, evolve WM, save |
| ACTIVE | `recordInsight()` | ACTIVE | Route insight, evolve WM, enforce limits, save |
| ACTIVE | Inactivity > 2h, then `recordInsight()` or `restore()` | EXPIRED → CREATED | Expire old, create new |
| ACTIVE | Toggle disabled | ENDED | Cancel compression, clear session, delete file |
| ACTIVE | triggerCompression() | ACTIVE (compressing) | Async task running |
| ACTIVE (compressing) | Compression completes | ACTIVE | Apply result, save |
| ACTIVE (compressing) | Toggle disabled | ENDED | Cancel task, clear, delete |
| ACTIVE (compressing) | New compression triggered | ACTIVE (compressing) | Cancel old task, start new |
| ENDED | Toggle enabled | CREATED | Create new session |
| EXPIRED | (auto) | CREATED | Create new session |

### 13.3 Working Memory Sub-States

Working Memory has a simpler lifecycle within the active session:

```
    ┌──────────┐
    │  NULL    │  No WM (new session or legacy)
    └────┬─────┘
         │ First insight
         v
    ┌──────────┐
    │ ACTIVE   │  Content being evolved
    └────┬─────┘
         │
    ┌────┴─────────┐
    │              │
Topic switch    Over budget
    │              │
    v              v
┌──────────┐  ┌──────────┐
│ RESET    │  │COMPRESSING│
│ (→ACTIVE)│  └────┬─────┘
└──────────┘       │
                   v
              ┌──────────┐
              │ ACTIVE   │  (compressed)
              └──────────┘
```

---

## 14. Concurrency

### 14.1 Actor Isolation

VirtualSessionManager is isolated to the **main actor** (main thread). All public methods execute on the main thread. This matches the coordinator pattern in Decode — all UI-facing state mutations happen on the main thread.

### 14.2 Why Main Actor

1. **Coordinator integration**: Coordinators are main-actor-isolated. If VirtualSessionManager were on a different actor, every call would require an `await`, adding complexity and potential race conditions.
2. **UI synchronization**: The Memory Inspector reads from `activeSession` directly. Main-actor isolation guarantees the UI always sees consistent state without synchronization primitives.
3. **Simplicity**: Virtual Session state is small and mutations are fast. There is no benefit to off-loading to a background thread.

### 14.3 Compression Task

The only concurrent operation is the compression task. It is spawned as a background task but its start and completion are on the main actor.

**Lifecycle**:
1. `triggerCompression()` runs on the main actor: cancels any existing task, spawns new async task.
2. The new task runs `performCompression()`:
   a. Reads Working Memory content on the main actor.
   b. Calls `provider.generateCompletion()` which internally runs the network request asynchronously.
   c. When the LLM responds, the result is processed back on the main actor.
   d. Working Memory is updated and saved on the main actor.

**Race Prevention**:
- Only one compression task exists at a time (`compressionTask` property).
- New triggers cancel the old task.
- After the LLM responds, the task checks whether the session is still active before applying the result.
- Session end and expiration cancel the compression task.

### 14.4 Generation Counter Pattern

Virtual Session does not use the generation counter pattern. The generation counter pattern is used by coordinators to prevent stale explanation results from being displayed. Virtual Session's `recordInsight()` is called from the coordinator's `onComplete` callback, which already benefits from the coordinator's generation counter — if the coordinator has moved on to a new request, the old callback is never called.

### 14.5 Thread Safety Invariants

1. All `activeSession` mutations happen on the main actor.
2. `compressionTask` is only read/written on the main actor.
3. `lastRetrievedInsights` is only read/written on the main actor.
4. Persistence (file I/O) happens synchronously on the main actor. The file is small (a few KB at most).
5. All `nonisolated static` methods are pure functions with no mutable state.

---

## 15. Error Handling

### 15.1 LLM Unavailable

**Scenario**: AI provider is not configured or returns null.

**Handling**: `performCompression()` falls back to `deterministicCompress()`. All other Virtual Session operations are deterministic and do not require the LLM.

**Impact**: Compression quality is lower (deterministic eviction vs. intelligent summarization). All other functionality is unaffected.

### 15.2 Compression LLM Failure

**Scenario**: AI provider is available but the `generateCompletion()` call throws an error (network failure, API error, timeout).

**Handling**: The error is caught, logged (debug builds only), and `deterministicCompress()` is called as fallback.

**Impact**: Same as LLM unavailable — lower quality compression.

### 15.3 Compression Response Invalid

**Scenario**: LLM returns a response but it is too short (<30 chars) or too long (>250 chars).

**Handling**: Response is rejected, logged (debug builds only), and `deterministicCompress()` is called.

**Impact**: Same as above.

### 15.4 Persistence Write Failure

**Scenario**: The JSON file cannot be written (disk full, permissions error, directory doesn't exist).

**Handling**: The error is caught and logged (debug builds only). The in-memory session state is preserved. The next mutation will attempt to write again.

**Impact**: If the app terminates before a successful write, the session state since the last successful write is lost. On restart, the last successfully persisted state is loaded.

### 15.5 Persistence Read Failure

**Scenario**: The JSON file exists but cannot be read or decoded (corrupt file, incompatible schema, I/O error).

**Handling**: `load()` returns null. `restore()` starts a fresh session.

**Impact**: Any previously persisted session state is lost. The user starts with a clean session. No error is shown to the user — the system silently recovers.

### 15.6 Corrupt Session State

**Scenario**: The in-memory session state somehow becomes inconsistent (e.g., investigation with null anchor after deserialization).

**Handling**: The system is designed to tolerate partial nulls. All new fields are optional. The Knowledge Evolution Algorithm bootstraps `knowledgeSentences` from null. The Memory Inspector falls back to raw insights when `currentUnderstanding` is null.

### 15.7 Session Expired During Compression

**Scenario**: An async compression task completes but the session has expired or been ended while the LLM was processing.

**Handling**: `performCompression()` checks `activeSession?.workingMemory != nil` after the LLM call. If the session is gone, the result is silently discarded.

**Impact**: None. The LLM call is wasted but no incorrect state is written.

### 15.8 Understanding Extraction Failure

**Scenario**: The explanation text contains no meaningful content (empty, whitespace-only, only headers, only bullets).

**Handling**: `extractUnderstanding()` returns the generic fallback: `"Explored code selected in {sourceApp}"` (or `"an application"` if sourceApp is null).

**Impact**: A low-quality insight is recorded. This is acceptable — it indicates the user asked about something but the explanation was not extractable. The investigation's knowledge evolution algorithm will not replace higher-quality existing sentences with this low-quality one.

---

## 16. Invariants

The following invariants must hold in any correct implementation of Virtual Session.

### 16.1 Structural Invariants

1. **At most one active session.** There is never more than one VirtualSession in existence.
2. **At most one Working Memory.** A session has zero or one WorkingMemory.
3. **Investigation count bounded.** `investigations.count <= maxInvestigationCount` (5) after every `recordInsight()` call.
4. **Insight count bounded.** `totalInsightCount <= maxInsightCount` (20) after every `recordInsight()` call.
5. **Character count bounded.** `totalCharacterCount <= maxTotalCharacters` (3000) after every `recordInsight()` call, modulo a single insight potentially exceeding the budget (one insight is always retained).
6. **Working Memory content bounded.** `workingMemory.content.count <= maxContentCharacters` (1000) after deterministic eviction. May briefly exceed during async compression.
7. **Topic keywords bounded.** `workingMemory.topicKeywords.count <= maxTopicKeywords` (40) after every evolution.
8. **Investigations are append-ordered.** New investigations are always appended to the end. The active investigation is always the last.

### 16.2 Temporal Invariants

9. **Expiration is checked before recording.** `expireIfNeeded()` is called before `recordInsight()` creates or modifies any investigation.
10. **Persistence after every mutation.** `save()` is called after every state-changing operation.
11. **Compression never blocks explanations.** Compression runs asynchronously and is never awaited by the coordinator or the recording flow.

### 16.3 Data Integrity Invariants

12. **Understanding extraction is deterministic.** `extractUnderstanding()` is a pure function. Given the same explanation text, it always returns the same understanding.
13. **Knowledge evolution is deterministic.** Given the same existing sentences and new understanding, the evolution algorithm always produces the same result.
14. **Insights are immutable after creation.** Once created, an Insight's fields are never modified. Insights are only created or evicted.
15. **Investigations are never reordered.** Investigations maintain creation order. Eviction removes from the front (oldest first).

### 16.4 Concurrency Invariants

16. **At most one compression task.** Only one async compression runs at a time. New triggers cancel the old.
17. **Compression results are guarded.** Compression checks session liveness before applying results.
18. **Session end cancels compression.** `endSession()` and `expireIfNeeded()` cancel in-flight compression.

### 16.5 Injection Invariants

19. **Working Memory injection is unconditional.** If WM has non-empty content, it is injected. No scoring, no threshold.
20. **Injection happens before the LLM call.** WM is appended to the system prompt before the explanation request is sent.
21. **Recording happens after the LLM call.** Insights are recorded in the `onComplete` callback after the stream finishes.
22. **Injection and recording are ordered.** For any single explanation, injection uses the WM state *before* the explanation, and recording produces the WM state *after* the explanation. There is no circular dependency.

---

## 17. Performance

### 17.1 Character Limits

| Resource | Limit | Rationale |
|----------|-------|-----------|
| Working Memory content | 1000 chars | ~250 tokens. Negligible system prompt overhead. |
| WM compression target | 250 chars | ~60 tokens. Minimal ongoing prompt cost. |
| Investigation understanding | 600 chars | Enough for 3-5 dense sentences. |
| Insight understanding | 200 chars | Enough for 1-2 sentences. |
| Total insight characters | 3000 chars | Bounded archival cost. |
| Total insights | 20 | Bounded iteration cost. |
| Total investigations | 5 | Bounded iteration cost. |
| Topic keywords | 40 | Bounded comparison cost. |

### 17.2 Memory Footprint

A fully loaded session occupies approximately:
- 5 investigations × 4 insights × 200 chars = 4000 chars of understanding text.
- Working Memory: ~1000 chars.
- Anchors, metadata, UUIDs, timestamps: ~2000 chars of overhead.
- Total: ~7000 chars ≈ 7 KB in memory.

This is negligible for any modern platform.

### 17.3 Computational Complexity

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Recording an insight | O(I × S) | I = total insights, S = sentences. Dominated by knowledge evolution. |
| Knowledge evolution | O(N × E) | N = new sentences, E = existing sentences. Overlap comparison. |
| Eviction | O(S²) | S = sentences. Repeated linear scan for minimum. |
| Topic switching | O(K) | K = topic keywords. Set intersection. |
| Affinity scoring | O(R) | R = related entities. Small constant. |
| Persistence | O(D) | D = total data size. JSON serialization. |

All operations are fast because the data structures are small (bounded by the limits above). A full session has at most 20 insights across 5 investigations, with ~40 topic keywords and ~10 knowledge sentences. No operation exceeds millisecond latency.

### 17.4 Why No Embeddings

Embedding-based retrieval was considered and rejected for the current implementation:

1. **Scale does not justify it.** With at most 20 insights and 5 investigations, linear scoring is fast enough.
2. **Structural signals are stronger.** File path and entity name matches are binary and precise. Embeddings would add noise.
3. **No embedding model dependency.** Virtual Session should work without any ML model. The only optional LLM dependency is compression.
4. **Latency.** Embedding computation adds latency to every recording and retrieval. At current scale, it would be slower than linear scoring.

Embeddings may become valuable at future scales (see Section 19).

### 17.5 Why Deterministic Topic Switching

LLM-based topic detection was considered and rejected:

1. **Latency.** Topic switching must be synchronous — it determines whether to reset Working Memory before the next recording. An LLM call would block recording.
2. **Cost.** An LLM call for every insight recording would double the API cost of Virtual Session.
3. **Reliability.** Deterministic switching always works. LLM switching could fail or hallucinate.
4. **Transparency.** Users can understand why a topic switch occurred (keyword overlap or structural change). LLM decisions are opaque.

The tradeoff is occasional false positives (switching when subtopics are genuinely related) and false negatives (not switching when topics are genuinely different but share keywords). At the current scale, this tradeoff is acceptable.

---

## 18. Testing Strategy

### 18.1 Test Coverage

The Virtual Session test suite validates every major component and interaction.

#### VS-01: Session Lifecycle (7 tests)

| Test | Validates |
|------|-----------|
| Start creates session | `startSession()` creates a session with empty investigations |
| Start is idempotent | Calling `startSession()` twice keeps the first session |
| End clears session | `endSession()` sets session to null |
| End is idempotent | Calling `endSession()` twice is safe |
| Toggle on starts | `handleToggleChanged(true)` starts a session |
| Toggle off ends | `handleToggleChanged(false)` ends a session |
| Toggle on keeps existing | Toggle on with existing session preserves it |

#### VS-02: Investigation Creation (8 tests)

| Test | Validates |
|------|-----------|
| First insight creates investigation | First recording creates investigation with correct theme |
| Same file continues | Second insight in same file continues investigation |
| Related entity continues | Insight for a related entity continues investigation |
| Unrelated starts new | Different file/module/layer starts new investigation |
| Module+layer overlap continues | Same module+layer but different file continues |
| Theme updates (multi-file) | Theme changes when investigation spans multiple files |
| Theme updates (cross-module) | Theme changes when investigation spans 3+ modules |
| Anchor expands | Anchor grows as insights accrue |

#### VS-03: Expiration (5 tests)

| Test | Validates |
|------|-----------|
| Not expired when recent | Fresh session does not expire |
| Expires after threshold | Old session expires |
| Recent insight prevents | Recent insight prevents expiration even if session started long ago |
| `expireIfNeeded` returns false | Returns false for non-expired session |
| Record on expired triggers | Recording on expired session restarts |

#### VS-04: Persistence (6 tests)

| Test | Validates |
|------|-----------|
| Save and load round-trip | Session survives JSON serialization |
| Load returns null for missing | No file returns null |
| Load returns null for corrupt | Corrupt file returns null |
| End deletes file | `endSession()` removes persisted file |
| Anchor codable | InvestigationAnchor round-trips through JSON |
| InsightContext codable | InsightContext round-trips through JSON |

#### VS-05: Restoration (4 tests)

| Test | Validates |
|------|-----------|
| Restores persisted | Valid persisted session is loaded |
| Discards expired | Expired persisted session is replaced |
| Clears when disabled | Toggle off + persisted file = clean slate |
| Starts fresh when no file | No persisted file starts new session |

#### VS-06: Storage Limits (4 tests)

| Test | Validates |
|------|-----------|
| Evicts on count overflow | Oldest insights evicted when count > 20 |
| Evicts on character overflow | Oldest insights evicted when chars > 3000 |
| Evicts oldest investigations | Oldest investigation evicted when count > 5 |
| Cleans empty investigations | Empty investigations removed after eviction |

#### VS-07: Boundary Detection (6 tests)

| Test | Validates |
|------|-----------|
| Same entity continues | Entity name match prevents new investigation |
| Related entity continues | Related entity overlap prevents new investigation |
| Unrelated starts new | No overlap starts new investigation |
| Module only with few entities | Module overlap alone with <=2 entities starts new |
| Module only with many entities | Module overlap with >2 entities continues |
| Selection mode minimal | Minimal context (Selection Mode) starts new |

#### VS-08: Data Model (4+ tests)

| Test | Validates |
|------|-----------|
| Total insight count | Computed property sums correctly |
| Total character count | Computed property sums correctly |
| Anchor absorption | `absorb()` merges context into anchor |
| Anchor absorption additive | Multiple absorptions don't duplicate |

#### VS-09: Retrieval Scoring (5+ tests)

| Test | Validates |
|------|-----------|
| Empty when no session | Returns empty without active session |
| Matches same file path | File path match produces results |
| Excludes below threshold | Low-score insights filtered |
| Ordered by score | Results sorted by descending score |
| Respects character budget | Character limit enforced |

#### VS-10: Affinity Score (5 tests)

| Test | Validates |
|------|-----------|
| File path scores highest | File match = 0.5 |
| Entity scores higher | Entity + file > file alone |
| Unrelated scores zero | No overlap = 0.0 |
| Score capped at 1.0 | Maximum score is 1.0 |
| Source app adds small score | Source app match = 0.05 |

#### VS-11: Prompt Augmentation (3 tests)

| Test | Validates |
|------|-----------|
| Null when no session | Returns null without session |
| Null when no relevant insights | Returns null when nothing matches |
| Correct format | Output matches expected format |

#### VS-20: Understanding Extraction (28 tests)

Tests cover all four extraction strategies:
- TLDR tag extraction (5 tests): extraction, priority, empty/whitespace handling.
- First paragraph (5 tests): normal paragraphs, skipping headers/bullets.
- First sentence (1 test): fallback to sentence extraction.
- Cleaning (4 tests): XML tag removal, markdown removal, whitespace normalization, truncation.
- Fallback (4 tests): empty input, whitespace input, bullet-only input, null sourceApp.
- Edge cases (3 tests): multi-section, bold-within-sentence, single sentence.

#### VS-21: Working Memory Model (5 tests)

| Test | Validates |
|------|-----------|
| Defaults | Empty WM has expected defaults |
| Codable round-trip | WM survives JSON serialization |
| Backward compatibility | Session without WM field deserializes correctly |

#### VS-22: Working Memory Lifecycle (4 tests)

| Test | Validates |
|------|-----------|
| Creation | First insight creates WM |
| Evolution | Subsequent insights evolve WM |
| Persistence | WM survives save/load |
| Cleanup | Session end clears WM |

#### VS-23: Working Memory Prompt Injection (4 tests)

| Test | Validates |
|------|-----------|
| Null when no session | Returns null without session |
| Null when no WM | Returns null with session but no WM |
| Null when empty content | Returns null when WM content is empty |
| Formatted output | Returns correct format when content exists |

#### VS-24: Topic Keyword Extraction (5 tests)

| Test | Validates |
|------|-----------|
| Basic extraction | Extracts meaningful keywords |
| Stop word filtering | Filters programming-generic stop words |
| Short word filtering | Filters words < 3 characters |
| Numeric filtering | Filters all-numeric words |
| Uniqueness | No duplicate keywords |

#### VS-25: Topic Switching (7 tests)

| Test | Validates |
|------|-----------|
| Structural switch | Different file triggers switch in Session Mode |
| Structural no-switch | Same file prevents switch |
| Semantic switch | Zero keyword overlap triggers switch |
| Semantic no-switch | Keyword overlap prevents switch |
| Insufficient evidence | <2 keywords prevents switch |
| Reset on switch | WM content is replaced on switch |
| Keyword accumulation | Keywords accumulate across insights |

#### VS-26: Working Memory Evolution (4 tests)

| Test | Validates |
|------|-----------|
| Deduplication | Overlapping sentences replaced |
| Density replacement | Richer sentences replace sparser ones |
| Append new | Non-overlapping sentences appended |
| Bounds | Content stays within character budget |

#### VS-27: Deterministic Compression (1 test)

| Test | Validates |
|------|-----------|
| Bounded after many insights | After many insights, WM stays within 1000 chars |

### 18.2 Testing Approach

**Unit tests**: Each algorithm (knowledge evolution, topic switching, keyword extraction, affinity scoring, understanding extraction, sentence decomposition, word overlap, importance scoring) is tested in isolation.

**Integration tests**: The recording flow (insight → investigation routing → knowledge evolution → WM evolution → limit enforcement → persistence) is tested end-to-end.

**Persistence tests**: Save/load round-trips, corrupt file handling, missing file handling, backward compatibility with older schemas.

**No LLM tests**: All tests use deterministic algorithms. LLM compression is not tested because it depends on an external service. Deterministic compression (the fallback) is tested.

---

## 19. Future Extension Points

The following extensions can be made without changing the core architecture.

### 19.1 Embedding-Based Retrieval

**Current**: Linear affinity scoring with structural signals.

**Extension**: Compute embeddings for insight understandings and Working Memory content. Use cosine similarity for retrieval instead of structural matching.

**Integration point**: Replace `affinityScore()` with embedding-based scoring. No other changes needed. The retrieval API (`relevantInsights()`, `formatInsightBlock()`) and character budgets remain the same.

**When**: When session scale grows beyond 20 insights (the current maximum), or when structural signals are insufficient (e.g., multiple workspaces, multiple languages).

### 19.2 Cloud Synchronization

**Current**: Local JSON file persistence.

**Extension**: Sync the JSON file to a cloud service (e.g., user's cloud storage, Decode backend).

**Integration point**: Replace `save()` and `load()` with cloud-aware persistence. The data model is already JSON-serializable.

**Considerations**: Session expiration (2 hours) limits the value of cross-device sync. Cloud sync is more useful for backup/recovery than for real-time cross-device continuity.

### 19.3 Cross-Device Memory

**Current**: Sessions are device-local.

**Extension**: Share session state across devices via a server.

**Integration point**: Same as cloud sync, plus conflict resolution for concurrent modifications on different devices.

**Considerations**: Requires a conflict resolution strategy. Last-writer-wins is sufficient given the 2-hour session lifetime.

### 19.4 Semantic Retrieval

**Current**: Retrieval uses structural affinity scoring (file path, entity name, module, layer).

**Extension**: Add semantic similarity scoring based on the content of understandings, not just their structural metadata.

**Integration point**: Add a semantic score component to `affinityScore()`.

### 19.5 Adaptive Compression

**Current**: Fixed compression target (250 characters).

**Extension**: Adapt the compression target based on context window availability, session age, or topic complexity.

**Integration point**: Make `compressionTargetCharacters` dynamic instead of static.

### 19.6 Multi-Session History

**Current**: One session at a time. Previous sessions are discarded.

**Extension**: Maintain a history of past sessions. Allow the user to browse and restore previous investigations.

**Integration point**: Modify `endSession()` to archive instead of delete. Add a session history UI.

### 19.7 LLM-Based Topic Detection

**Current**: Deterministic keyword and structural comparison.

**Extension**: Use the LLM to determine whether two understandings are about the same topic.

**Integration point**: Replace `shouldSwitchWorkingMemory()` with an LLM call (async, with deterministic fallback).

**Tradeoff**: Higher accuracy but adds latency and cost to every insight recording.

### 19.8 Quality-Scored Understanding Extraction

**Current**: Deterministic extraction pipeline (TLDR → paragraph → sentence → fallback).

**Extension**: Use the LLM to generate a high-quality understanding summary instead of extracting from the explanation text.

**Integration point**: Replace `extractUnderstanding()` with an LLM call (async). The recording flow would need to become async.

**Tradeoff**: Higher quality understandings but adds latency and cost. Currently rejected because the deterministic pipeline produces adequate results.

---

## 20. Appendix

### 20.1 Understanding Extraction Algorithm (Detailed)

The understanding extraction pipeline converts raw LLM explanation text into a concise, clean understanding string. It operates in four ranked strategies with cleaning and truncation.

#### Strategy 1: TLDR Tag (Highest Priority)

If the explanation contains a `<tldr>...</tldr>` tag (produced by the explanation prompt framework), extract its content. This is the highest-quality source because the LLM was explicitly asked to produce a summary.

**Detection**: Parse the explanation for tagged segments, find the first TLDR-tagged segment.

**Validation**: Content must be non-empty after trimming whitespace.

#### Strategy 2: First Meaningful Paragraph

Split the explanation on blank lines (double newlines). For each paragraph:
1. Split into lines.
2. Skip lines that are **section headers**: lines consisting entirely of bold text (e.g., `**Quick Explanation**`). A section header starts with `**` and ends with `**` with no additional `**` inside.
3. Skip bullet points: lines starting with `•`, `- `, or `* `.
4. Skip numbered list items: lines starting with a digit followed by `. `.
5. Collect remaining content lines.
6. Join them with spaces.
7. Return the first paragraph with content lines.

**Validation**: Must pass the "meaningful" check (>= 3 words).

#### Strategy 3: First Meaningful Sentence

Scan all lines of the explanation:
1. Skip section headers and bullet points (same rules as Strategy 2).
2. For each remaining line, find the first sentence boundary (period followed by space or end-of-string).
3. If a sentence with >= 3 words is found, return it.
4. If a line with >= 4 words but no period is found, return the entire line.

#### Strategy 4: Generic Fallback

Return: `"Explored code selected in {sourceApp}"` (or `"an application"` if sourceApp is null).

#### Cleaning

After extraction, the text is cleaned:
1. Remove XML-style tags: regex `</?[a-zA-Z][a-zA-Z0-9]*>` → empty string.
2. Remove markdown bold: regex `\*\*([^*]+)\*\*` → capture group (the text inside).
3. Remove markdown inline code: regex `` `([^`]+)` `` → capture group.
4. Normalize whitespace: regex `\s+` → single space.
5. Trim leading/trailing whitespace.

#### Truncation

If the cleaned text exceeds `maxUnderstandingLength` (200 characters):
1. Take the first 200 characters.
2. Look for the last period within this prefix. If found and it's past the first third of the limit (>66 chars), truncate at that period.
3. Otherwise, look for the last space and truncate there.
4. If no space found, use the raw 200-character prefix.

### 20.2 Sentence Decomposition Algorithm

The sentence decomposition algorithm splits text into individual knowledge sentences:

1. Split the input text by newline characters.
2. For each line (after trimming whitespace, skipping empty lines):
   a. Scan character by character looking for period boundaries.
   b. A period is a sentence boundary if:
      - It is the last character in the line, OR
      - It is followed by a space, AND the character after the space is uppercase or is the last character.
   c. When a boundary is found, emit the accumulated text as a sentence, start accumulating again.
   d. After scanning, emit any remaining text as a final sentence.
3. Filter out sentences with fewer than 3 words.

**Important**: This algorithm handles abbreviations and decimal numbers imperfectly. "The API uses v2.0 endpoints" would split at "v2.0" if followed by an uppercase letter. This is an accepted limitation — the knowledge evolution algorithm handles occasional mis-splits gracefully because short fragments are filtered.

### 20.3 Word Overlap Formula

```
wordOverlap(a, b):
    wordsA = unique lowercase words in a
    wordsB = unique lowercase words in b
    if min(|wordsA|, |wordsB|) == 0: return 0.0
    return |wordsA ∩ wordsB| / min(|wordsA|, |wordsB|)
```

The denominator uses `min()` rather than `max()` or the union. This means that a short sentence that is entirely contained within a longer sentence will score 1.0 (full overlap). This is intentional: if every word in the shorter sentence appears in the longer one, they cover the same ground even if the longer one has additional detail.

### 20.4 Information Score Formula

```
informationScore(text):
    words = lowercase words in text
    return count of words NOT in stopWords
```

The stop words set contains 50 common English words (see Section 5.6). Information score represents how many "meaningful" words a sentence contains. A sentence like "The function validates the token" has an information score of 2 ("function", "validates", "token" — wait, "function" IS in topic stop words but NOT in base stop words. Information score uses base `stopWords`, not `topicStopWords`).

Correction: Information score uses the base `stopWords` set (50 words). Topic keyword extraction uses the extended `topicStopWords` set (127 words). These are different sets used for different purposes.

### 20.5 Example Session Walkthrough

**Scenario**: User investigates authentication in Session Mode, then switches to database queries.

**Step 1**: User opens `Auth.swift`, asks about `validate()`.

```
Understanding: "Auth validates JWT tokens using HMAC-SHA256 signatures"
Context: filePath=/src/Auth.swift, entityName=Auth.validate, moduleName=Authentication, layer=application

Manager state after:
- Investigation #1: theme="Understanding Auth.swift"
  - Insight: "Auth validates JWT tokens using HMAC-SHA256 signatures"
  - Anchor: filePaths={/src/Auth.swift}, entityNames={Auth.validate}, moduleNames={Authentication}
  - currentUnderstanding: "Auth validates JWT tokens using HMAC-SHA256 signatures"
- Working Memory:
  - content: "Auth validates JWT tokens using HMAC-SHA256 signatures"
  - keywords: [auth, validates, jwt, tokens, hmac, sha256, signatures]
  - anchor: filePaths={/src/Auth.swift}, entityNames={Auth.validate}
```

**Step 2**: User asks about `checkExpiration()` in the same file.

```
Understanding: "Token expiration is checked against server time with clock skew tolerance"
Context: filePath=/src/Auth.swift, entityName=Auth.checkExpiration

Investigation boundary: filePath match → continue
Topic switch: filePath match → no switch

Manager state after:
- Investigation #1: theme="Understanding Auth.swift"
  - 2 insights
  - currentUnderstanding: "Auth validates JWT tokens using HMAC-SHA256 signatures\nToken expiration is checked against server time with clock skew tolerance"
- Working Memory:
  - content: "Auth validates JWT tokens using HMAC-SHA256 signatures\nToken expiration is checked against server time with clock skew tolerance"
  - keywords: [..., expiration, checked, server, clock, skew, tolerance]
```

**Step 3**: User opens `Database.swift`, asks about `query()`.

```
Understanding: "Database query optimizer uses index scans for range predicates"
Context: filePath=/src/Database.swift, entityName=Database.query, moduleName=Storage, layer=infrastructure

Investigation boundary: no file/entity/module overlap → NEW investigation
Topic switch: no structural overlap → SWITCH

Manager state after:
- Investigation #1: (unchanged, archival)
- Investigation #2: theme="Understanding Database.swift"
  - 1 insight
  - currentUnderstanding: "Database query optimizer uses index scans for range predicates"
- Working Memory: RESET
  - content: "Database query optimizer uses index scans for range predicates"
  - keywords: [database, query, optimizer, index, scans, range, predicates]
  - anchor: filePaths={/src/Database.swift}, entityNames={Database.query}
```

### 20.6 Example Working Memory Evolution

Starting state:
```
sentences: [
  KnowledgeSentence("Auth validates JWT tokens using HMAC-SHA256.", reinforcement=2),
  KnowledgeSentence("Tokens have a 24-hour expiration window.", reinforcement=0)
]
```

New understanding: "Auth validates JWT and OAuth tokens using cryptographic signatures."

**Sentence decomposition**: ["Auth validates JWT and OAuth tokens using cryptographic signatures."]

**Evolution step for this candidate**:
1. `candidateScore = informationScore("Auth validates JWT and OAuth tokens using cryptographic signatures.")` = count non-stop words = 7 (auth, validates, jwt, oauth, tokens, cryptographic, signatures).
2. Word overlap with sentence 0: "Auth validates JWT tokens using HMAC-SHA256." Overlap = {auth, validates, jwt, tokens, using} / min(7, 6) = 5/6 = 0.83 ≥ 0.6 → **match**.
3. `existingScore = informationScore("Auth validates JWT tokens using HMAC-SHA256.")` = 6 (auth, validates, jwt, tokens, hmac, sha256).
4. `candidateScore (7) > existingScore (6)` → **replace**.
5. Result: sentence 0 becomes "Auth validates JWT and OAuth tokens using cryptographic signatures." with reinforcement reset to 0.

Final state:
```
sentences: [
  KnowledgeSentence("Auth validates JWT and OAuth tokens using cryptographic signatures.", reinforcement=0),
  KnowledgeSentence("Tokens have a 24-hour expiration window.", reinforcement=0)
]
```

### 20.7 Example Compression Cycle

**Before compression** (Working Memory content = 1100 characters):
```
sentences: [
  "Auth validates JWT tokens using HMAC-SHA256 signatures with configurable secret." (reinforcement=3),
  "Token expiration uses server-time comparison with 5-minute clock skew tolerance." (reinforcement=1),
  "Refresh tokens are stored encrypted in the system keychain with biometric gate." (reinforcement=0),
  "The auth middleware intercepts all API requests and validates Bearer tokens." (reinforcement=2),
  "Failed authentication returns 401 with a machine-readable error code." (reinforcement=0),
  "Rate limiting applies per-IP with 100 requests per 5-minute sliding window." (reinforcement=0),
  ... (more sentences)
]
```

**Deterministic eviction** (target: 1000 chars):
Repeatedly remove the sentence with lowest importance score. "Failed authentication returns 401..." (low information density, reinforcement=0, not last) is evicted first. Then "Rate limiting applies..." (reinforcement=0, not auth-related, low density).

**Still over 1000 chars**: trigger async LLM compression.

**LLM compression prompt**: sends all remaining content, asks for summary under 250 chars.

**LLM response** (validated: 180 chars):
```
"Auth validates JWT/OAuth via HMAC-SHA256 with configurable secret. Tokens expire by server-time (5min skew). Refresh tokens: encrypted keychain + biometric. Middleware validates all Bearer requests."
```

**Applied**: content replaced, sentences re-decomposed, compressionCount incremented.

### 20.8 Glossary

| Term | Definition |
|------|------------|
| **Virtual Session** | A temporary, bounded memory container spanning all Decode modes. |
| **Working Memory** | The operational, prompt-injected knowledge layer. Resets on topic switch. |
| **Investigation** | A structural grouping of related insights (living knowledge document). |
| **Insight** | A single distilled understanding from one Decode interaction. |
| **Investigation Anchor** | Accumulated structural metadata (files, entities, modules) defining an investigation's scope. |
| **Knowledge Evolution** | The algorithm that integrates new sentences into existing knowledge via deduplication, replacement, reinforcement, and eviction. |
| **Topic Switching** | The detection mechanism that resets Working Memory when the user changes subjects. |
| **Compression** | The process of reducing Working Memory content via LLM summarization or deterministic eviction. |
| **Affinity Score** | A structural similarity metric between two InsightContexts, used for retrieval ranking. |
| **Topic Keywords** | Meaningful words extracted from understandings, used for semantic topic switching. |
| **Topic Stop Words** | Programming-generic words excluded from topic keyword extraction (superset of base stop words). |
| **Information Score** | Count of meaningful (non-stop-word) words in a sentence, used for density comparison. |
| **Reinforcement Count** | How many times a KnowledgeSentence was matched but not replaced (higher = more foundational). |
| **Importance Score** | Composite score (density + reinforcement + recency) used for eviction ordering. |
| **Deterministic Compression** | Fallback compression via importance-scored sentence eviction. |
| **Memory Inspector** | UI popover displaying the current Virtual Session state. |
| **Prompt Augmentation** | The injection of Working Memory content into the system prompt before the LLM call. |
| **Understanding Extraction** | Deterministic pipeline that converts raw explanation text into a concise understanding string. |

---

*End of VAS-001: Virtual Session Architecture Specification*

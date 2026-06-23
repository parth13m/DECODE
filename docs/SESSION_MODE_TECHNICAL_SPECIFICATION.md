# Decode — Session Mode & File Intelligence
# Technical Specification / Engineering Handbook

**Version**: 1.0
**Date**: 2026-06-23
**Phase**: File Intelligence Complete · Module Intelligence Pending
**Audience**: Senior software engineer joining the project

---

## Table of Contents

1. [Product Overview](#1-product-overview)
2. [User Experience](#2-user-experience)
3. [High-Level Architecture](#3-high-level-architecture)
4. [Complete Runtime Flow](#4-complete-runtime-flow)
5. [File Intelligence](#5-file-intelligence)
6. [Deterministic Facts Engine](#6-deterministic-facts-engine)
7. [Semantic Enrichment Engine](#7-semantic-enrichment-engine)
8. [Explanation Engine](#8-explanation-engine)
9. [LLM Usage](#9-llm-usage)
10. [Token Usage Analysis](#10-token-usage-analysis)
11. [Performance Characteristics](#11-performance-characteristics)
12. [Component Reference](#12-component-reference)
13. [Testing Guide](#13-testing-guide)
14. [Engineering Decisions](#14-engineering-decisions)
15. [Current Limitations](#15-current-limitations)
16. [Future Roadmap](#16-future-roadmap)
17. [Readiness Assessment](#17-readiness-assessment)

---

## 1. Product Overview

### What Decode Is

Decode is a native macOS AI code explanation tool. Users highlight code in any editor, press a hotkey, and get an instant AI-powered explanation in a floating HUD. It is designed for engineers who want to understand unfamiliar code quickly — the experience should feel like asking a knowledgeable colleague who has already read the entire file.

### Three Modes of Operation

| Mode | Trigger | Input Source | Context |
|------|---------|-------------|---------|
| **Selection** | Double-tap Control | Accessibility API text capture | Snippet only (no file context) |
| **Screenshot** | Double-tap Option | Drag-select screen region → OCR | OCR text (no file context) |
| **Session** | `⌃⇧O` to open file, then Double-tap Shift | Accessibility API text capture | Full file understanding (File Intelligence) |

Session Mode is the most sophisticated. It opens a file, parses its AST, builds layered understanding (File Intelligence), and uses that understanding to anchor every explanation in the file's structure, purpose, and architecture.

### Backend Architecture

The AI provider is server-side. Users never configure API keys.

```
Client (Swift, macOS 15+)
    │
    │ HTTPS (Bearer token auth)
    ▼
Backend (FastAPI + PostgreSQL on Railway)
    │
    │ AI_ADAPTER=anthropic, AI_MODEL=claude-haiku-4-5-20251001
    ▼
LLM Provider (Anthropic API)
```

Authentication: Admin generates invite code → user enters invite code → server returns access token → client stores raw token in Keychain → SHA-256 hash stored server-side → all subsequent requests use Bearer auth.

### Scale

Pre-beta alpha, invite-only, 5–50 users. The codebase optimizes for correctness and developer experience, not high-concurrency scalability.

---

## 2. User Experience

### Session Mode User Flow

```
1. User presses ⌃⇧O
       │
       ▼
2. Decode opens NSOpenPanel (file picker)
       │
       ▼
3. User selects a source file (e.g., SessionManager.swift)
       │
       ▼
4. Decode parses the file:
   ├── AST extraction (entities, imports, relationships)
   ├── Identity classification (role, layer, patterns)
   ├── Purpose derivation (one-sentence deterministic purpose)
   └── Structure outline generation
       │
       ▼
5. Session appears as a capsule pill in the floating dock
   (non-activating NSPanel on right screen edge)
       │
       ▼
6. User highlights code in their editor
       │
       ▼
7. User presses Double-tap Shift
       │
       ▼
8. Decode:
   ├── Captures selected text via Accessibility API
   ├── Resolves which session the snippet belongs to
   ├── Builds snippet-anchored context (tier 1–3)
   ├── Classifies snippet health (tree-sitter error analysis)
   ├── Triggers semantic enrichment (lazy, cached LLM call)
   ├── Selects relevant understanding layers (question-aware)
   ├── Checks usage quota
   ├── Assembles system prompt + user message
   └── Streams AI response to floating HUD
       │
       ▼
9. User sees explanation in floating HUD
   ├── Can ask follow-up questions (3-message conversation)
   └── Can request code improvement (Improve button)
```

### Floating Session Dock

The dock is a non-activating `NSPanel` anchored to the right edge of the screen. Each open session appears as a capsule pill. Features:

- **Magnification**: pills scale up on hover (dock-like effect)
- **Active indicator**: the currently active session is visually distinguished
- **Context menu**: right-click to pin a session (forces all question routing to that session) or close it
- **Auto-visibility**: dock appears when sessions exist, hides when none remain

### Follow-Up Questions

After an explanation, the user can type follow-up questions in the HUD. The follow-up system uses a dedicated `followUpSystemPrompt` (NOT the explanation prompt) and a 3-message conversation:

```
Message 1 (user):    Original code / question
Message 2 (assistant): The explanation that was just generated
Message 3 (user):    The follow-up question
```

This gives the LLM full context of what was already explained.

### Code Improvement

After an explanation, the user can click "Improve" to get an improved version of the selected code. The improvement:

- Uses `<improvement_summary>` and `<improved_code>` XML tags for structured parsing
- In Session Mode, reuses the exact `SessionContext` from the explanation (no re-parsing)
- Can determine that no improvement is needed (returns summary-only, no `<improved_code>` tag)
- Replace action: clipboard backup → write improved code → simulated ⌘V → clipboard restore

---

## 3. High-Level Architecture

### Layered Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    PRESENTATION                         │
│  FloatingExplanationHUD · ExplanationHUDViewModel       │
│  FloatingSessionDock · SessionView · SessionViewModel   │
│  ExplanationTagParser · ImprovementSectionView          │
├─────────────────────────────────────────────────────────┤
│                    APPLICATION                          │
│  SessionQuestionCoordinator · SelectionModeCoordinator  │
│  ScreenshotModeCoordinator · SessionManager             │
│  SessionResolver · ContextBuilderService                │
│  SemanticEnrichmentService · ExplanationFramework        │
│  RepresentationGuidance · SnippetHealthClassifier       │
│  FileIdentityClassifier · FilePurposeDeriver            │
│  ImprovementService · AIUsageTracker                    │
├─────────────────────────────────────────────────────────┤
│                      DOMAIN                             │
│  Session · CodeEntity · SessionContext · AILimits        │
│  FileIntelligence · FileIdentity · SemanticEnrichment   │
│  ParsedEntity · Relationship · ImportDeclaration        │
│  DetailedParseResult · AIProviderProtocol               │
│  DatabaseProtocol                                       │
├─────────────────────────────────────────────────────────┤
│                   INFRASTRUCTURE                        │
│  DecodeGatewayProvider · AccessibilityCapture            │
│  HotkeyService · SwiftSyntaxParser · TreeSitterParser   │
│  DatabaseService · KeychainService · FileWatcherService  │
│  ScreenCaptureService · VisionOCRService                │
│  TextReplacementService · AnalyticsEventService          │
└─────────────────────────────────────────────────────────┘
```

**Strict downward dependency**: each layer may only import from layers below it. Protocols at the Domain layer enable dependency inversion (e.g., `AIProviderProtocol` is in Domain, `DecodeGatewayProvider` implements it in Infrastructure).

### Dependency Injection

Manual DI via `AppDependencies` — a `@Observable @MainActor` class that serves as the root container. No framework. All dependencies are constructed in `AppDependencies` and passed via closures or direct injection.

Key pattern: coordinators receive the AI provider as a `@MainActor () -> (any AIProviderProtocol)?` closure rather than a direct reference. This allows the provider to be rebuilt (e.g., after authentication) without reconstructing the coordinator.

### App Lifecycle

```
DecodeApp.init()
    │
    ▼
AppDependencies.init()     ← Lightweight: no I/O, no Keychain, no permissions
    │
    ▼
NSApplication.didBecomeActiveNotification
    │
    ▼
performDeferredStartup()   ← All activation-sensitive work:
    ├── Auth check + provider rebuild
    ├── Database initialization
    ├── Coordinator wiring
    ├── Session Manager + View Model creation
    ├── Session Dock creation
    ├── SemanticEnrichmentService creation
    ├── Hotkey fan-out setup (single stream → 3 coordinator streams)
    └── Accessibility permission prompt (gated on authenticated state)
```

### Hotkey Fan-Out

The `HotkeyService` produces a single `AsyncStream<HotkeyEvent>`. Since `AsyncStream` is single-consumer, `AppDependencies` consumes it and fans out each event to three separate streams — one for each coordinator:

```
HotkeyService.startListening()
        │
        │ single AsyncStream<HotkeyEvent>
        ▼
AppDependencies (fan-out task)
    ├── selContinuation.yield(event)  → SelectionModeCoordinator
    ├── ssContinuation.yield(event)   → ScreenshotModeCoordinator
    └── sqContinuation.yield(event)   → SessionQuestionCoordinator
```

Each coordinator filters for its own action (`.explainSelection`, `.captureScreenshot`, `.askSessionQuestion`) and ignores the rest.

The `openSession` action (`⌃⇧O`) is handled directly in the fan-out task — no coordinator needed.

---

## 4. Complete Runtime Flow

This section traces every step of a Session Question request, from hotkey press to explanation display.

### Step 0: Preconditions

Before any of this runs, the following must be true:

- `performDeferredStartup()` has executed
- User is authenticated (access token in Keychain)
- `aiProvider` is non-nil (gateway provider constructed)
- At least one session is open (user pressed `⌃⇧O` and selected a file)
- The session's file has been parsed (entities, imports, relationships extracted)
- `FileIntelligence` has been built (identity classified, purpose derived)

### Step 1: Hotkey Detection

```
User presses Shift twice rapidly
    │
    ▼
HotkeyService detects double-tap Shift
    │
    ▼
Yields HotkeyEvent(action: .askSessionQuestion, sourceAppPID: ..., sourceAppName: ...)
    │
    ▼
Fan-out yields to SessionQuestionCoordinator's stream
    │
    ▼
SessionQuestionCoordinator.startListening() receives event
    │
    ▼
requestGeneration += 1                ← Increment generation counter
activeRequestTask?.cancel()           ← Cancel any in-flight request
activeRequestTask = Task {            ← Start new request task
    handleSessionQuestion(event:, generation:)
}
```

**Generation-counter pattern**: Each new hotkey press increments `requestGeneration` and cancels the previous task. Throughout the flow, generation checks (`guard generation == requestGeneration`) detect when a newer request has superseded this one. This eliminates the need for mutexes or locks.

### Step 2: Validation Gates (Steps 1–3 in code)

```
handleSessionQuestion(event:, generation:)
    │
    ├── 1. guard aiProvider() != nil
    │   └── Fail: "Connecting to Decode Gateway..."
    │
    ├── 2. guard sessionProvider() != nil
    │   └── Fail: "No active session. Open a file..."
    │
    └── 3. guard selectionCapture.hasAccessibilityPermission()
        └── Fail: request permission, show toast
```

### Step 3: Text Capture (Step 4 in code)

```
guard event.sourceAppPID != nil
    │
    ▼
captureResult = try await selectionCapture.captureSelection(fromPID:)
    │
    ▼
guard generation == requestGeneration    ← Staleness check after await
    │
    ▼
guard captureResult != nil && !result.text.isWhitespaceOnly
    │
    ▼
snippetText = result.text
if snippetText.count > 15,000:           ← AILimits.maxSelectedTextCharacters
    snippetText = prefix(15,000) + "[Truncated...]"
```

### Step 4: Session Resolution (Step 6 in code)

```
SessionResolver.resolve(
    snippet: snippetText,
    sessions: resolverInput.sessions,        ← All open sessions
    pinnedSessionId: resolverInput.pinnedSessionId,
    activeSessionId: resolverInput.activeSessionId
)
    │
    ├── Pinned? → Return pinned session (confidence=100)
    │
    ├── Single session? → Return it (confidence=100)
    │
    ├── Snippet < 15 chars? → Fallback to active session
    │
    └── Score all sessions:
        │
        ├── Entity containment (exact):     100 points
        ├── Entity containment (normalized): 80 points
        ├── File content match:              60 points
        ├── Recency bonus:                   10 (most recent), 5 (second), ...
        ├── Active session bonus:            5 points
        │
        ├── Best score ≥ 60?
        │   ├── Gap to second < 10? → Ambiguous → Fallback to active
        │   └── Clear winner → Auto-resolved
        │
        └── Best score < 60? → Fallback to active session
```

**Key design detail**: Entity containment scoring requires NO file I/O — it uses `parsedEntities[].sourceText` which is already in memory. File content matching (tier 3 scoring) does require reading the file from disk, but only as a fallback.

### Step 5: Context Building (Step 7 in code)

```
ContextBuilderService.buildContext(
    session: managed.session,
    parsedEntities: managed.parsedEntities,
    snippet: snippetText
)
```

The context builder produces a `SessionContext` using one of four tiers:

```
┌─────────────────────────────────────────────────────────┐
│                   TIER SELECTION                        │
│                                                         │
│  locateSnippet(snippet, entities)                       │
│      │                                                  │
│      ├── Match found?                                   │
│      │   └── TIER 1: Entity-matched context             │
│      │       - Containing entity source code            │
│      │       - Parent type signature                    │
│      │       - Sibling method signatures                │
│      │       - Structure outline with ← selected marker │
│      │       - hasSourceInContext = true                 │
│      │                                                  │
│      └── No match                                       │
│          │                                              │
│          ├── File ≤ 200 lines?                          │
│          │   └── TIER 2: Small file fallback            │
│          │       - Full file content                    │
│          │       - ← SELECTED START/END markers         │
│          │       - hasSourceInContext = true             │
│          │                                              │
│          ├── Snippet found by text search?              │
│          │   └── TIER 2.5: Local context fallback       │
│          │       - ±30 surrounding lines                │
│          │       - Nearest entity signatures above/below│
│          │       - Positional outline marker             │
│          │       - hasSourceInContext = true             │
│          │                                              │
│          └── Not found                                  │
│              └── TIER 3: Large file fallback            │
│                  - Structure outline only               │
│                  - hasSourceInContext = false            │
│                  - Snippet goes in user message          │
└─────────────────────────────────────────────────────────┘
```

**Snippet location strategy**: The `locateSnippet` method first tries exact containment (`entity.sourceText.contains(snippet)`), then falls back to whitespace-normalized matching. When multiple entities match, it picks the smallest (most specific) one.

**Token reduction**: Context tiers achieve ~63–97% token reduction compared to sending the full file.

### Step 6: Code Health Classification (Step 8 in code)

```
SnippetHealthClassifier.classify(
    snippet: snippetText,
    language: grammarRegistration,
    fullFileSource: fullFileContent       ← For validation
)
```

The classifier:

1. Parses the snippet in isolation with tree-sitter
2. Collects all ERROR and MISSING nodes
3. Classifies each error as **edge** (boundary artifact) or **interior** (likely real)
4. If full file source is available, validates: does the same region have errors in the full file?
   - If full file is clean at that location → all errors are boundary artifacts → `silent`
5. Assigns a tier:

```
                    ┌──────────────────────┐
                    │   Error Collection   │
                    └──────────┬───────────┘
                               │
            ┌──────────────────┼──────────────────┐
            │                  │                   │
     No errors          Edge errors only      Interior errors
         │                     │                   │
      SILENT            ≥4 edges?            ≥3 interior?
                        │    │               │    │
                       yes   no             yes   no
                        │    │               │    │
                    OBSERVE SILENT       DIAGNOSE  │
                                                   │
                                            ≥1 interior?
                                            │    │
                                           yes   no
                                            │    │
                                        SURFACE  SILENT
```

Each tier modifies the system prompt differently:
- **silent**: No prompt changes
- **observe**: Gentle permission to mention issues
- **surface**: Injects evidence, asks LLM to use judgment
- **diagnose**: Injects evidence, asks LLM to prioritize diagnosis

### Step 7: Semantic Enrichment (Step 9 in code)

```
SemanticEnrichmentService.enrich(intelligence: fileIntelligence)
    │
    ├── Cache hit (fileHash match)? → Return cached SemanticEnrichment
    │
    ├── No AI provider? → Return nil
    │
    └── Cache miss:
        │
        ├── buildFactsSummary(intelligence)    ← ~200-500 tokens
        │   ├── File metadata (name, language, lines)
        │   ├── Identity (role summary)
        │   ├── Preliminary purpose
        │   ├── Types with grouped members (up to 15 types, 20 members each)
        │   ├── Top-level functions (up to 20)
        │   ├── Dependencies (deduplicated module names)
        │   ├── Relationships (inheritances, conformances, ownerships ≤10)
        │   ├── Entry points (entities that call but are never called)
        │   └── External calls (targets not defined in this file)
        │
        ├── buildEnrichmentPrompt()           ← System prompt
        │   └── Requests 4 XML-tagged sections:
        │       <purpose>, <behavior>, <safety>, <design>
        │
        ├── provider.generateCompletion(...)   ← Non-streaming LLM call
        │
        ├── Parse response:
        │   ├── <purpose> found? → use it
        │   │   └── Not found? → entire response = purpose (backward compat)
        │   ├── <behavior> found? → use it, else nil
        │   ├── <safety> found? → use it, else nil
        │   └── <design> found? → use it, else nil
        │
        ├── Cache result by fileHash
        │
        └── Return SemanticEnrichment
```

**Critical**: Enrichment runs BEFORE the quota check. It is infrastructure, not a user-visible request. The enrichment LLM call does NOT consume user quota.

**Staleness check**: After the `await enrich()` call returns, the coordinator checks `generation == requestGeneration` — if a newer request arrived during the LLM call, this one is abandoned.

### Step 8: Question-Aware Context Selection (Step 9b in code)

```
selectContextLayers(
    snippet: snippetText,
    fileRole: managed.fileIntelligence?.identity.role
)
```

Purpose is ALWAYS included. The other three layers (Behavior, Safety, Design) are included or excluded based on keyword signals in the snippet and the file's role:

```
Signal Category          Keywords (examples)                    Layers Activated
─────────────────────    ─────────────────────────────────────  ─────────────────
Error handling           catch, throw, guard, Result, Error     Safety
Concurrency              async, await, Task, actor, lock        Safety + Behavior
State/control flow       switch, for, while, @Published         Behavior
Design patterns          protocol, class, struct, init          Design

File Role                                                       Layers Activated
─────────────────────                                           ─────────────────
coordinator/manager/service                                     Behavior + Design
model/protocolDefinition                                        Design
view/viewModel                                                  Behavior
parser                                                          Behavior
test                                                            Behavior
```

If NO signals are detected from either source, ALL layers are included (fallback to `.all`).

When a layer is excluded, the corresponding enrichment variable is set to `nil`, which causes `ContextBuilderService.buildSystemPrompt` to omit that section.

### Step 9: Quota Check (Step 10 in code)

```
AIUsageTracker.tryConsumeRequest()
    │
    ├── Under limit (100 requests / 5-hour rolling window)? → true
    │
    └── Over limit? → false → Show quota toast, return
```

The quota is tracked client-side via `UserDefaults`. Server-side rate limiting is a separate concern.

### Step 10: Prompt Assembly (Step 11 in code)

```
ContextBuilderService.buildSystemPrompt(
    context:        sessionContext,       ← From Step 5
    sourceApp:      sourceAppName,
    snippet:        snippetText,
    dsaMode:        UserDefaults bool,
    fileIdentity:   identity,            ← Deterministic
    filePurpose:    enrichedPurpose ?? deterministicPurpose,
    fileBehavior:   enrichedBehavior,    ← May be nil (filtered)
    fileSafety:     enrichedSafety,      ← May be nil (filtered)
    fileDesign:     enrichedDesign,      ← May be nil (filtered)
    fileImports:    intelligence.imports
)
```

The system prompt is assembled in this order:

```
1. Role declaration ("You are Decode, a code explanation tool...")

2. File header: name, entity count

3. File structure outline (with ← selected marker or ← snippet here)

4. File understanding layers (only non-nil):
   ├── **Role**: identity.summary
   ├── **Purpose**: semantic or deterministic purpose
   ├── **Behavior**: semantic behavior understanding
   ├── **Safety**: semantic safety understanding
   ├── **Design**: semantic design understanding
   └── **Dependencies**: deduplicated import module names

5. Snippet location description

6. Source code (tier-dependent):
   ├── Tier 1: Containing entity source in code fence
   ├── Tier 2: Full file content in code fence (with markers)
   ├── Tier 2.5: Surrounding ±30 lines + nearest entities
   └── Tier 3: (no source — outline only)

7. Session context instructions (tier-specific guidance)

8. Language-specific guidance (non-Swift files)

9. Explanation framework style instructions:
   ├── Language hint (e.g., "This is imperative code...")
   ├── V7 adaptive instructions OR DSA instructions
   └── Tag vocabulary

10. Source application note

11. Code Health augmentation (tier-dependent):
    ├── silent: nothing
    ├── observe: gentle permission
    ├── surface: evidence + judgment
    └── diagnose: evidence + prioritize

12. ARE representation guidance:
    ├── Recursion → "include a worked example trace"
    ├── Complex generics → "show the data shape"
    ├── State management → "map the states and triggers"
    ├── Async-heavy → "show the event sequence"
    ├── Enum with cases → "compare them concisely"
    └── Simple / no signal → nothing
```

**User message construction**:

```
if context.hasSourceInContext:
    "Explain the selected code."        ← Source is already in system prompt
else:
    "Explain this code:\n\n{snippet}"   ← Tier 3: snippet must be in message
```

### Step 11: Streaming and Display

```
provider.streamChat(
    messages: [AIMessage(role: .user, content: userMessage)],
    systemPrompt: systemPrompt,
    mode: "session",
    contextTier: context.contextTier,
    explanationProfile: dsaMode ? "dsa" : "general",
    language: detectedLanguage
)
    │
    ▼
Generation check after streamChat returns
    │
    ▼
Build FollowUpContext (stores all state for follow-ups and improvement)
    │
    ▼
hud.showStream(stream, sourceApp:, followUpContext:)
    │
    ▼
ExplanationHUDViewModel receives AsyncThrowingStream<String, Error>
    │
    ▼
Tag parser processes chunks in real-time:
    ├── <hl>text</hl>        → highlighted identifier
    ├── <critical>text</critical> → danger callout
    ├── <tip>text</tip>      → fix suggestion (pairs with <critical>)
    ├── <note>text</note>    → non-obvious behavior
    ├── <flow>diagram</flow> → vertical flow diagram
    ├── <tldr>text</tldr>    → one-sentence lead insight
    └── <analogy>text</analogy> → reserved, not used
    │
    ▼
User sees explanation rendered in floating HUD
```

---

## 5. File Intelligence

### What File Intelligence Is

File Intelligence is the layered understanding Decode builds about each source file. It mirrors how an experienced engineer comprehends a file: first recognizing what it is (Identity), then understanding why it exists (Purpose), then how it operates (Behavior), how it handles failure (Safety), and finally its architectural role (Design).

### The Five Understanding Layers

```
Layer 5: Design      ← Semantic (LLM-derived, lazy, cached)
Layer 4: Safety      ← Semantic (LLM-derived, lazy, cached)
Layer 3: Behavior    ← Semantic (LLM-derived, lazy, cached)
Layer 2: Purpose     ← Deterministic + Semantic augmentation
Layer 1: Identity    ← Deterministic (computed at parse time)
─────────────────────
Foundation: Deterministic Facts (entities, imports, relationships, outline)
```

| Layer | Source | When Computed | Cost | Field |
|-------|--------|---------------|------|-------|
| Identity | Deterministic | At parse time | Zero (no LLM) | `FileIntelligence.identity` |
| Purpose | Deterministic + LLM | Parse time (deterministic), first question (semantic) | One LLM call (shared) | `FileIntelligence.purpose` + `SemanticEnrichment.purpose` |
| Behavior | Semantic | First question | One LLM call (shared) | `SemanticEnrichment.behavior` |
| Safety | Semantic | First question | One LLM call (shared) | `SemanticEnrichment.safety` |
| Design | Semantic | First question | One LLM call (shared) | `SemanticEnrichment.design` |

All four semantic layers are computed in a SINGLE LLM call, not four separate calls. The enrichment prompt requests all four via XML tags in one response.

### The FileIntelligence Struct

Defined in `Decode/Domain/Models/FileIntelligence.swift` (79 lines):

```swift
struct FileIntelligence: Sendable {
    let sessionId: UUID
    let fileName: String
    let language: String
    let lineCount: Int
    let entities: [ParsedEntity]
    let structureOutline: String
    let imports: [ImportDeclaration]
    let relationships: [Relationship]
    let identity: FileIdentity           // Layer 1
    let purpose: String                  // Layer 2 (deterministic)
    var semanticEnrichment: SemanticEnrichment?  // Layers 2-5 (semantic)
    let fileHash: String                 // Cache invalidation key
    let buildDate: Date
}
```

Note: `semanticEnrichment` is `var` — the only mutable field. This is intentional: the struct is immutable at construction time, but semantic enrichment is lazily populated on first user question.

### When Intelligence Is Built

```
createSession(url:) or reparseSession(id:)
    │
    ▼
parseFile(source:, url:)                    ← AST extraction
    │ Returns DetailedParseResult:
    │   .entities: [ParsedEntity]
    │   .imports: [ImportDeclaration]
    │   .relationships: [Relationship]
    │
    ▼
buildFileIntelligence(session:, parseResult:, source:)
    ├── detectLanguage(fileName:)
    ├── count lines
    ├── buildStructureOutline(entities:)
    ├── FileIdentityClassifier.classify(...)  ← Layer 1: Identity
    ├── FilePurposeDeriver.derivePurpose(...) ← Layer 2: Purpose
    └── Construct FileIntelligence
    │
    ▼
sessions[id]?.fileIntelligence = intelligence
```

Semantic enrichment (Layers 2-5) is NOT computed here. It happens lazily during the first `handleSessionQuestion` call, via `SemanticEnrichmentService.enrich()`.

### Cache Invalidation

FileIntelligence is keyed by `fileHash` (SHA-256 of the file content). When the file changes:

1. `FileWatcherService` detects the modification (watches parent directory, not file directly)
2. `SessionManager.reparseSession(id:)` is called
3. New source is read, re-parsed, new `FileIntelligence` built with new `fileHash`
4. Old semantic enrichment becomes stale (different `fileHash`)
5. Next user question triggers a new enrichment LLM call (cache miss)

---

## 6. Deterministic Facts Engine

### Philosophy

"Deterministic first." Everything that can be objectively determined from the AST is computed deterministically. The LLM is never asked to infer what can be determined objectively. This creates a permanent, reliable foundation that semantic enrichment augments but never replaces.

### Parser Architecture

Two parser implementations produce the same output type (`DetailedParseResult`):

```
Source File
    │
    ├── .swift extension?
    │   └── SwiftSyntaxParser (via SwiftSyntax 600.0.1)
    │       ├── EntityCollector (SyntaxVisitor)
    │       ├── CallExtractor
    │       └── parseAllFacts() → DetailedParseResult
    │
    └── Other extensions?
        └── TreeSitterParser (via SwiftTreeSitter)
            ├── 9 language grammars
            ├── .scm query files per language
            └── parseAllFacts() → DetailedParseResult
```

### DetailedParseResult

```swift
struct DetailedParseResult {
    let entities: [ParsedEntity]
    let imports: [ImportDeclaration]
    let relationships: [Relationship]
}
```

### Entities (ParsedEntity)

Each parsed entity wraps a `CodeEntity` with structural metadata:

```swift
struct ParsedEntity {
    let entity: CodeEntity          // id, sessionId, stableId, entityType, name, hash
    let signature: String           // Declaration without body
    let startLine: Int              // 1-based
    let endLine: Int                // 1-based
    let sourceText: String          // Full source including body
    let fileName: String
    let parentStableId: String?     // Parent type's stableId, nil if top-level
}
```

Entity types: `.class`, `.struct`, `.enum`, `.protocol`, `.function`, `.method`, `.property`.

The `stableId` is a hash of the entity body — deterministic and unique within a file. Used for relationship edges and database diff-based sync.

### Imports (ImportDeclaration)

```swift
struct ImportDeclaration {
    let moduleName: String          // "Foundation", "numpy", "react"
    let importedSymbols: [String]   // ["path"] for `from os import path`
    let kind: ImportKind            // .module, .symbol, .wildcard, .sideEffect
    let line: Int                   // 1-based
    let rawText: String             // "import Foundation"
}
```

### Relationships

```swift
struct Relationship {
    let kind: RelationshipKind      // .calls, .conformsTo, .inherits, .owns
    let sourceEntity: String        // stableId of the originating entity
    let targetName: String          // Symbolic name of the target
    let line: Int                   // 1-based
}
```

Four relationship kinds:

| Kind | Example | Notes |
|------|---------|-------|
| `.calls` | `validate()` call inside `createSession()` | Target may be external |
| `.conformsTo` | `struct User: Codable` | Swift limitation: can't distinguish superclass from protocol on classes |
| `.inherits` | `class Foo: BaseClass` | Language-specific detection |
| `.owns` | `let parser: SwiftParser` inside `SessionManager` | Nested types and stored properties |

### TreeSitterParser (1,252 lines)

Supports 9 languages via `.scm` query files:

| Language | Grammar | Entities | Imports | Calls |
|----------|---------|----------|---------|-------|
| Python | tree-sitter-python | entities.scm | imports.scm | calls.scm |
| JavaScript | tree-sitter-javascript | entities.scm | imports.scm | calls.scm |
| TypeScript | tree-sitter-typescript | entities.scm | imports.scm | calls.scm |
| Java | tree-sitter-java | entities.scm | imports.scm | calls.scm* |
| C# | tree-sitter-c-sharp | entities.scm | imports.scm | calls.scm* |
| C | tree-sitter-c | entities.scm | imports.scm | calls.scm |
| C++ | tree-sitter-cpp | entities.scm | imports.scm | calls.scm |
| HTML | tree-sitter-html | entities.scm | — | — |
| CSS | tree-sitter-css | entities.scm | — | — |

*Java/C# calls queries don't capture `@callee` — the parser extracts the callee from the call text using `extractCalleeFromCallText()`.

**Post-processing pipeline**: After tree-sitter query execution, the parser performs:
1. Entity deduplication (by stableId)
2. HTML semantic filtering (removes trivial elements)
3. Parent relationship resolution (assigning `parentStableId` based on line ranges)
4. Import parsing (language-specific: Python `from...import`, JS `import...from`, Java `import`, C `#include`, etc.)
5. Inheritance/conformance extraction (language-specific patterns)

### SwiftSyntaxParser

Uses Apple's SwiftSyntax library for Swift-specific parsing. Two-pass approach:

1. **EntityCollector** (`SyntaxVisitor`): Walks the syntax tree collecting classes, structs, enums, protocols, functions, methods, properties with full source text and signatures.
2. **CallExtractor**: Extracts function call relationships.

Both produce `DetailedParseResult` with the same shape as TreeSitterParser output.

### Identity Classification (FileIdentityClassifier, 268 lines)

Three-stage heuristic, priority-ordered:

```
Stage 1: File name patterns (strongest signal)
    ├── "Tests" / "Test" / "Spec" suffix → .test
    ├── "App" suffix → .appEntry
    ├── "Coordinator" suffix → .coordinator
    ├── "ViewModel" suffix → .viewModel
    ├── "View" / "HUD" / "Overlay" suffix → .view
    ├── "Manager" suffix → .manager
    ├── "Service" suffix → .service
    ├── "Parser" / "Transformer" suffix → .parser
    ├── "Protocol" / "Interface" suffix → .protocolDefinition
    └── "Config" / "Constants" suffix → .configuration

Stage 2: Entity composition (when name isn't conclusive)
    ├── Mostly protocols → .protocolDefinition
    ├── Types with few methods → .model
    └── Mostly free functions → .configuration

Stage 3: Path-based layer detection
    ├── /presentation/, /views/, /ui/ → .presentation
    ├── /application/, /coordinators/ → .application
    ├── /domain/, /models/ → .domain
    ├── /infrastructure/, /services/ → .infrastructure
    └── /tests/, /test/ → .testing
```

Output: `FileIdentity` with `role: FileRole` (13 cases), `layer: ArchitecturalLayer` (6 cases), `patterns: [String]`, `summary: String`.

Pattern detection finds: Observable state container, Dependency injection, Delegate pattern, Singleton, Async/await concurrency, Visitor pattern, Algebraic data type.

### Purpose Derivation (FilePurposeDeriver, 432 lines)

Produces a one-sentence purpose statement. Role-dispatched:

| Role | Strategy | Example Output |
|------|----------|----------------|
| manager/coordinator/service | Extract responsibilities from method names | "Manages session lifecycle — session creation, file watching, and session restoration." |
| viewModel | Extract actions from method names | "Drives the explanation HUD UI — transforms state for presentation." |
| view | Name decomposition | "Presents the floating explanation interface." |
| model | Field theme extraction | "Represents session — an identifiable record with metadata." |
| protocol | Method summary | "Defines the contract for AI provider — generate completion and stream chat." |
| parser | Subject extraction | "Extracts structured information from Swift syntax input." |
| test | Subject extraction | "Tests session resolver." |
| appEntry | Pattern matching | "Root dependency container — constructs and wires all services." |

Key algorithm: `extractResponsibilities()` extracts verb-object pairs from method names (`createSession` → "session creation"), groups by theme frequency, returns top 3.

---

## 7. Semantic Enrichment Engine

### Architecture

```
SemanticEnrichmentService (Application layer)
    │
    ├── In-memory cache: [String: SemanticEnrichment]
    │   keyed by fileHash
    │
    ├── buildFactsSummary(intelligence:)
    │   └── Structured facts → ~200-500 tokens
    │
    ├── buildEnrichmentPrompt()
    │   └── System prompt requesting 4 XML sections
    │
    └── provider.generateCompletion(...)
        └── Non-streaming LLM call (mode: "enrichment")
```

### Cache Design

- **Key**: `fileHash` (SHA-256 of file content)
- **Storage**: In-memory `Dictionary<String, SemanticEnrichment>`
- **Eviction**: None (resets on app restart)
- **Invalidation**: Automatic — when the file changes, `fileHash` changes, cache misses
- **Concurrency**: `@MainActor` isolation — no concurrent access concerns

At alpha scale (5–50 users, handful of sessions per user), memory usage is negligible. No disk persistence needed.

### Facts Summary Format

The `buildFactsSummary` method converts `FileIntelligence` into a structured text block. Example output for a typical coordinator file:

```
File: SessionQuestionCoordinator.swift
Language: swift
Lines: 515
Role: Coordinator · Application layer · 25 entities. Patterns: Dependency injection, Async/await concurrency
Preliminary purpose: Coordinates session question — session question handling and context selection.
Types:
  class SessionQuestionCoordinator
    init(selectionCapture:aiProvider:hud:toastManager:contextBuilder:sessionResolver:snippetHealthClassifier:sessionProvider:usageTracker:semanticEnrichment:)
    startListening(hotkeyStream:)
    stopListening()
    handleSessionQuestion(event:generation:)
    selectContextLayers(snippet:fileRole:)
    containsAny(_:keywords:)
  struct LayerSelection
  struct ActiveSessionSnapshot
  struct SessionResolverInput
Dependencies: AppKit, Foundation
Relationships:
  SessionQuestionCoordinator conforms to Sendable
  ActiveSessionSnapshot conforms to Sendable
Entry points: startListening, stopListening
External calls: captureSelection, resolve, buildContext, classify, enrich, ...
Internal calls: 8
```

This is ~200-500 tokens — a 90-95% reduction compared to sending the full 515-line source file (~2,000-10,000 tokens).

### Enrichment Prompt

The system prompt requests four XML-tagged sections:

```
1. PURPOSE: WHY this file exists, WHAT responsibility it owns (1-2 sentences)
2. BEHAVIOR: HOW it operates at runtime — triggers, collaboration, sequencing (2-3 sentences)
3. SAFETY: What to know before modifying — error handling, concurrency, assumptions (2-3 sentences)
4. DESIGN: Architectural responsibility, patterns, trade-offs (2-3 sentences)
```

Rules enforced:
- Focus on intent and responsibility, not implementation details
- Use relationships and external calls to understand context
- Improve upon the preliminary purpose (it's from naming heuristics)
- Do not list individual methods or repeat the structured facts
- No markdown formatting

### Response Parsing

Each XML tag is parsed independently with `extractTagContent(from:tag:)`. Graceful degradation:

```
<purpose> found?     → Use tagged content
<purpose> not found? → Entire response = purpose (backward compat)
<behavior> found?    → Use tagged content
<behavior> not found? → nil (coordinator omits from prompt)
<safety> found?      → Use tagged content
<safety> not found?  → nil (coordinator omits from prompt)
<design> found?      → Use tagged content
<design> not found?  → nil (coordinator omits from prompt)
```

If the LLM returns plain text without any tags (model failure, unexpected format), the entire response becomes the purpose and other layers are `nil`. The system continues to function.

### Failure Handling

```
LLM call throws error
    │
    ▼
enrich() returns nil
    │
    ▼
Coordinator:
    enrichedPurpose = nil
    enrichedBehavior = nil
    enrichedSafety = nil
    enrichedDesign = nil
    │
    ▼
buildSystemPrompt receives:
    filePurpose = nil ?? deterministicPurpose    ← Fallback
    fileBehavior = nil                           ← Omitted
    fileSafety = nil                             ← Omitted
    fileDesign = nil                             ← Omitted
```

The user never sees an error from enrichment failure. They get an explanation with deterministic purpose and no semantic augmentation — still a useful explanation.

---

## 8. Explanation Engine

### ExplanationFramework (7 frameworks)

The Explanation Framework detects the language family and provides a context hint for the LLM:

| Framework | Languages | Focus |
|-----------|-----------|-------|
| imperativeFlow | Python, Swift, sync JS/TS | Data transformations, control flow |
| lifecycle | React, async JS/TS | When code runs, lifecycle timing |
| contract | Java, C# | Design pattern, key logic (skip boilerplate) |
| ownership | C, C++ | Memory ownership, lifetimes, resources |
| visualCascade | CSS | Visual effect, specificity, cascade |
| structural | HTML | Semantic role, accessibility |
| setPipeline | SQL | Result shape, set combinations |

**Selection strategy**:
- Session Mode: file extension (primary) + content analysis (for JS/TS disambiguation)
- Selection/Screenshot Mode: content heuristics only
- JSX/TSX extensions → always lifecycle
- JS/TS → check for React hooks, JSX patterns, async patterns → lifecycle or imperativeFlow

### V7 Adaptive Explanation Engine

The V7 prompt is a 7-chapter pipeline. Chapters 1–6 are internal reasoning (never shown to user). Chapter 7 is the only visible output.

```
CH1 — UNDERSTAND (internal)
    Purpose, inputs, outputs, workflow, responsibilities, dependencies

CH2 — ORGANIZE (internal)
    Code profile validation

CH3 — ANALYZE (internal)
    Core mechanism, decision points, data transformation, failures

CH4 — EXPLAIN (internal)
    Meaning before mechanics, audience-appropriate depth

CH5 — PRESENT (internal)
    Visual vs text decisions, diagram selection

CH6 — COMPRESS (internal)
    Essential / Helpful / Noise classification

CH7 — OUTPUT (shown to user)
    Adaptive structure from available components:
    ├── Quick Explanation (1-3 sentences)
    ├── Key Insight (the non-obvious thing)
    ├── Workflow (vertical diagram, only when order matters)
    ├── Table (3+ comparable items)
    ├── Hierarchy (nesting matters)
    ├── Branching Flowchart (3+ exit paths, branching is primary purpose)
    ├── Risks / Edge Cases
    └── Summary (3-8 sentences, only with multiple parts)
```

**Bug Override**: For errors, stack traces, or buggy code — lead with what's broken, skip normal structure.

**Formatting rules**: No markdown headings (`##` or `###`) — the HUD renderer uses `.inlineOnlyPreservingWhitespace`. Use `**bold**` for component labels.

### Tag Vocabulary (7 custom tags)

| Tag | Type | Purpose | Usage Frequency |
|-----|------|---------|-----------------|
| `<hl>` | Inline | Highlight key identifier | Common |
| `<critical>` | Inline | Bug or danger | When issues exist |
| `<tip>` | Inline | Fix for a `<critical>` | Only with `<critical>` |
| `<note>` | Inline | Non-obvious behavior | Moderate |
| `<flow>` | Block | Diagram using │ → ├─ └─ | When prose insufficient |
| `<tldr>` | Block | One-sentence lead insight | When 4+ bullets |
| `<analogy>` | Inline | Reserved | Do not use |

Rules: No nesting. No inventing tags. Most explanations need 0–1 tags.

### DSA Mode

Toggled via `dsaModeEnabled` UserDefaults key. Uses a separate prompt (`ExplanationFramework+DSA.swift`) optimized for algorithms, data structures, and interview preparation. Independently evolvable from V7.

### Representation Guidance (ARE Phase 1)

Advisory system that suggests representation strategies. Appended to the system prompt after the explanation framework.

6 signal detectors (first match wins):

1. **Recursion** (function calls itself) → "include a worked example trace"
2. **Complex generics** (angle bracket depth ≥3) → "show the data shape"
3. **State management** (state keywords + switch/case) → "map the states and triggers"
4. **Async-heavy** (≥3 async signals) → "show the event sequence"
5. **Enum with cases** (≥3 case declarations) → "compare them concisely"
6. **Simple/short** (≤4 meaningful lines) → no guidance

The LLM is always free to ignore guidance. ARE does not generate visuals, add tags, or change the UI.

---

## 9. LLM Usage

### Where LLM Calls Happen

Decode makes LLM calls in exactly these places:

| Call Site | Purpose | Streaming? | Counts as User Request? | Model |
|-----------|---------|------------|------------------------|-------|
| Explanation (all 3 modes) | Generate code explanation | Yes | Yes | claude-haiku-4-5 |
| Follow-up question | Answer follow-up | Yes | Yes | claude-haiku-4-5 |
| Code improvement | Generate improved code | Yes | Yes | claude-haiku-4-5 |
| Semantic enrichment | File understanding | No | **No** | claude-haiku-4-5 |

All calls go through the same backend gateway (`DecodeGatewayProvider` → FastAPI → Anthropic API).

### Quota System

- **Client-side**: `AIUsageTracker` — 100 requests per 5-hour rolling window. Persisted to UserDefaults.
- **Server-side**: Token tracking, cost estimation (in admin dashboard). No server-side rate limiting currently.
- **Enrichment exemption**: Semantic enrichment calls do NOT consume client-side quota. They are classified as infrastructure.

### LLM Call: Semantic Enrichment

```
Mode:          "enrichment"
Streaming:     No (generateCompletion)
System prompt: ~350 tokens (fixed enrichment prompt)
User message:  ~200-500 tokens (structured facts summary)
Total input:   ~550-850 tokens
Expected output: ~200-400 tokens (4 XML sections)
Frequency:     Once per file version (cached by fileHash)
```

### LLM Call: Explanation

```
Mode:          "session" / "selection" / "screenshot"
Streaming:     Yes (streamChat → AsyncThrowingStream<String, Error>)
System prompt: Variable, depends on tier:
    Tier 1: ~800-2,000 tokens (entity source + outline + layers + framework)
    Tier 2: ~1,000-5,000 tokens (full file + markers + layers + framework)
    Tier 2.5: ~600-1,500 tokens (surrounding lines + outline + layers + framework)
    Tier 3: ~300-800 tokens (outline only + layers + framework)
User message:  "Explain the selected code." or "Explain this code:\n\n{snippet}"
Max response:  4,096 tokens (AILimits.maxResponseTokens)
```

### LLM Call: Follow-Up

```
Mode:          "session_followup" / "selection_followup" / "screenshot_followup"
Streaming:     Yes
System prompt: followUpSystemPrompt (~100 tokens, concise, no sections)
Messages:      3-message conversation:
    [0] user: original question
    [1] assistant: the generated explanation
    [2] user: the follow-up question
Max response:  4,096 tokens
```

### LLM Call: Code Improvement

```
Mode:          "session_improve" / "selection_improve"
Streaming:     Yes
System prompt: Static ImprovementService.systemPrompt (~400 tokens)
               OR contextAwareSystemPrompt(context:) for Session Mode (~800-2,000 tokens)
User message:  "Improve this code:\n\n{snippet}"
Max response:  4,096 tokens
Response format: <improvement_summary>...</improvement_summary>
                 <improved_code>...</improved_code>
```

### Analytics Data Sent Per Request

Every LLM call (except enrichment) sends to the backend:

```
mode:                  "session" | "selection" | "screenshot" | compound variants
context_tier:          "tier1" | "tier2" | "tier2.5" | "tier3"
explanation_profile:   "general" | "dsa"
language:              "Swift" | "Python" | etc.
```

The backend logs: `user_id`, `mode`, `success`, `latency_ms`, `error_type`, `ai_provider`, `ai_model`, `prompt_tokens`, `completion_tokens`, `total_tokens`, `prompt_character_count`, `created_at`.

Mode and explanation_profile are orthogonal — they never encode into each other.

---

## 10. Token Usage Analysis

### Structured Facts vs Raw Source

The core token optimization: send entity signatures and relationships to the LLM, not raw source code.

| File | Raw Source Tokens | Structured Facts Tokens | Reduction |
|------|-------------------|------------------------|-----------|
| Small file (~50 lines) | ~500 | ~100-150 | 70-80% |
| Medium file (~200 lines) | ~2,000 | ~200-300 | 85-90% |
| Large file (~500 lines) | ~5,000 | ~300-500 | 90-94% |
| Very large file (~1,000+ lines) | ~10,000+ | ~400-500 | 95%+ |

The facts summary is bounded by entity/relationship limits: 15 types, 20 members each, 20 top-level functions, 10 ownership relationships, 5 entry points, 10 external calls.

### Context Tier Token Usage

Estimated total system prompt tokens (including framework instructions, all layers, etc.):

| Tier | When Selected | Source Tokens | Total Prompt Tokens | Token Reduction vs Full File |
|------|---------------|--------------|---------------------|------------------------------|
| Tier 1 | Entity match | Entity source only (~100-500) | ~800-2,000 | 63-85% |
| Tier 2 | Small file, no entity match | Full file (~500-2,000) | ~1,000-3,500 | 0-50% (small files) |
| Tier 2.5 | Large file, text search match | ~60 lines (~200-600) | ~600-1,500 | 85-92% |
| Tier 3 | Large file, no match | 0 (outline only) | ~300-800 | 95-97% |

### Per-Request Token Budget

```
Enrichment call:
    Input:  ~550-850 tokens
    Output: ~200-400 tokens
    Total:  ~750-1,250 tokens
    Cost:   ~$0.0001-0.0002 at Haiku pricing

Explanation call (typical Tier 1):
    Input:  ~1,000-1,500 tokens
    Output: ~500-2,000 tokens
    Total:  ~1,500-3,500 tokens
    Cost:   ~$0.0003-0.0007 at Haiku pricing

Follow-up call:
    Input:  ~500-2,500 tokens (3 messages + system prompt)
    Output: ~200-800 tokens
    Total:  ~700-3,300 tokens
    Cost:   ~$0.0001-0.0006 at Haiku pricing
```

### Question-Aware Layer Filtering Impact

When the context layer selector filters out irrelevant layers, it saves ~50-150 tokens per excluded layer from the system prompt. For a typical Tier 1 explanation:

```
All layers included:     ~1,500 tokens system prompt
2 layers filtered out:   ~1,200 tokens system prompt
Saving:                  ~300 tokens (~20% of system prompt)
```

---

## 11. Performance Characteristics

### Critical Path Latency

For a Session Question (Double-tap Shift → explanation visible):

```
Step                        First Request      Subsequent (cached enrichment)
────────────────────        ──────────────     ─────────────────────────────
Hotkey detection            ~50ms              ~50ms
Accessibility capture       ~100-300ms         ~100-300ms
Session resolution          ~1-10ms            ~1-10ms
Context building            ~5-50ms            ~5-50ms
Health classification       ~10-50ms           ~10-50ms
Semantic enrichment         ~1-3s (LLM call)   ~0ms (cache hit)
Layer selection             ~0.1ms             ~0.1ms
Quota check                 ~0.1ms             ~0.1ms
Prompt assembly             ~1-5ms             ~1-5ms
Network + LLM streaming     ~1-5s              ~1-5s
────────────────────        ──────────────     ─────────────────────────────
Total                       ~2.5-8.5s          ~1.2-5.5s
```

The enrichment LLM call dominates first-request latency. Subsequent questions against the same file version skip enrichment entirely (cache hit ≈ instantaneous).

### Memory Usage

```
Per session:
    Session struct:              ~200 bytes
    ParsedEntity array:          ~1-50 KB (depends on entity count)
    FileIntelligence:            ~2-100 KB (includes outline, entities)
    SemanticEnrichment:          ~1-2 KB (4 short text fields)
    FileWatcherService:          ~100 bytes

Enrichment cache:
    Per entry:                   ~1-2 KB
    Typical user (5 sessions):   ~5-10 KB

Total per session:               ~5-150 KB
Total for 10 sessions:           ~50 KB - 1.5 MB
```

At alpha scale, memory usage is negligible. No optimization needed.

### File System Operations

| Operation | When | I/O Type |
|-----------|------|----------|
| File read (parse) | Session creation, file modification | Disk read |
| File read (context building, Tier 2) | Each explanation for small files | Disk read |
| File read (session resolution, Tier 3 scoring) | Each explanation, fallback scoring only | Disk read |
| Directory watch | Continuous (per session) | DispatchSource |
| Database operations | Session create/update, entity sync | SQLite (GRDB) |

The file watcher watches the parent directory (not the file directly) to survive atomic saves. Editors like Xcode and VS Code perform atomic writes (write to temp file → rename), which would break a direct file watch.

---

## 12. Component Reference

### Application Layer

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| `SessionQuestionCoordinator` | `Application/SessionQuestionCoordinator.swift` | 515 | Orchestrates Session Question flow |
| `SessionManager` | `Application/SessionManager.swift` | 623 | Session lifecycle, file watching, persistence |
| `SessionResolver` | `Application/SessionResolver.swift` | 346 | Automatic session-to-snippet matching |
| `ContextBuilderService` | `Application/ContextBuilderService.swift` | 634 | Snippet-anchored context assembly |
| `SemanticEnrichmentService` | `Application/SemanticEnrichmentService.swift` | 379 | Lazy, cached LLM enrichment |
| `ExplanationFramework` | `Application/ExplanationFramework.swift` | 486 | Language detection, V7 prompt, tag vocabulary |
| `SnippetHealthClassifier` | `Application/SnippetHealthClassifier.swift` | 414 | Tree-sitter error analysis for code health |
| `FileIdentityClassifier` | `Application/FileIdentityClassifier.swift` | 268 | Deterministic role/layer/pattern classification |
| `FilePurposeDeriver` | `Application/FilePurposeDeriver.swift` | 432 | Deterministic purpose statement derivation |
| `ImprovementService` | `Application/ImprovementService.swift` | 297 | Improvement prompt construction and response parsing |
| `RepresentationGuidance` | `Application/RepresentationGuidance.swift` | 253 | ARE Phase 1 advisory representation hints |
| `AIUsageTracker` | `Application/AIUsageTracker.swift` | 84 | Rolling-window quota enforcement |

### Domain Layer

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| `FileIntelligence` | `Domain/Models/FileIntelligence.swift` | 79 | Root understanding model for a file |
| `FileIdentity` | `Domain/Models/FileIdentity.swift` | 115 | Role, layer, patterns, summary |
| `SemanticEnrichment` | `Domain/Models/SemanticEnrichment.swift` | 93 | LLM-derived purpose, behavior, safety, design |
| `ParsedEntity` | `Domain/Models/ParsedEntity.swift` | 46 | Entity with structural metadata |
| `Relationship` | `Domain/Models/Relationship.swift` | 85 | Typed directed edge between entities |
| `ImportDeclaration` | `Domain/Models/ImportDeclaration.swift` | 44 | Import dependency declaration |
| `DetailedParseResult` | `Domain/Models/DetailedParseResult.swift` | 23 | Container for parse output |
| `AIProviderProtocol` | `Domain/Protocols/AIProviderProtocol.swift` | 97 | AI provider contract |

### Infrastructure Layer

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| `SwiftSyntaxParser` | `Infrastructure/AST/SwiftSyntaxParser.swift` | ~600+ | Swift AST parsing via SwiftSyntax |
| `TreeSitterParser` | `Infrastructure/AST/TreeSitterParser.swift` | 1,252 | Multi-language AST parsing via tree-sitter |
| 14 `.scm` query files | `Infrastructure/AST/Queries/{lang}/` | ~10-40 each | Tree-sitter query patterns |

### Presentation Layer

| Component | Purpose |
|-----------|---------|
| `FloatingExplanationHUD` | Non-activating floating panel for explanations |
| `ExplanationHUDViewModel` | State machine: idle/loading/streaming/complete/error |
| `ExplanationTagParser` | Real-time tag parsing during streaming |
| `FloatingSessionDock` | Session capsule pills on screen edge |
| `SessionView` / `SessionViewModel` | Session management UI |

### App Layer

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| `AppDependencies` | `App/AppDependencies.swift` | 353 | Root DI container, deferred startup |

---

## 13. Testing Guide

### Current Test Coverage

13 test files exist in `DecodeTests/`. One pre-existing failure: `MockAIProvider` doesn't conform to `AIProviderProtocol` in `SelectionModeCoordinatorTests.swift:49`.

### Priority Testing Areas

| Component | Why Priority | What to Test |
|-----------|-------------|--------------|
| `ContextBuilderService` | Core context assembly, 4 tiers | Tier selection, outline marking, snippet location |
| `SessionResolver` | Automatic session matching | Scoring, ambiguity detection, edge cases |
| `SnippetHealthClassifier` | Code health evidence | Edge vs interior classification, full-file validation |
| `ExplanationTagParser` | Real-time rendering | Tag parsing, nesting rejection, malformed tags |
| `FileIdentityClassifier` | Identity classification | Role detection across file types |
| `FilePurposeDeriver` | Purpose derivation | Responsibility extraction, camelCase splitting |

### Testing Patterns

- **Deterministic components** (ContextBuilderService, SessionResolver, SnippetHealthClassifier, FileIdentityClassifier, FilePurposeDeriver): Full unit testing is possible. No LLM calls. Provide crafted entities/files and verify outputs.
- **LLM-dependent components** (SemanticEnrichmentService): Test with mock AI provider. Verify prompt construction, response parsing, cache behavior, error handling.
- **Coordinators**: Integration-style tests with mock dependencies. Verify the flow orchestration and generation-counter behavior.

### Build and Run

```bash
xcodegen generate                    # After adding/removing Swift files
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Decode.xcodeproj -scheme Decode -configuration Debug build
```

Swift 6.0, `SWIFT_STRICT_CONCURRENCY = complete`, macOS 15.0, Xcode 16.2.

---

## 14. Engineering Decisions

### Why Structured Facts Instead of Raw Source

**Decision**: Send entity signatures, relationships, and imports to the enrichment LLM — not the source code.

**Rationale**:
1. **Token reduction**: 90-95% fewer input tokens. A 500-line file is ~5,000 tokens of source vs ~300-500 tokens of structured facts.
2. **Consistent format**: All languages produce the same structured format. The LLM doesn't need to parse Swift syntax differently from Python.
3. **Focus on structure**: The enrichment LLM's job is to interpret the file's architectural role, not to read code. Structured facts give it exactly the signals it needs.
4. **Cost control**: At scale, the token difference translates directly to cost savings.

**Trade-off accepted**: The LLM cannot see implementation details (specific algorithm choices, inline logic). This is intentional — implementation-level understanding is provided by the explanation LLM, which receives the actual source code.

### Why Lazy Semantic Enrichment

**Decision**: Compute semantic enrichment only when a user asks a question, not during file parsing.

**Rationale**:
1. **Cost**: Users may open sessions for files they never ask about. Eager enrichment wastes LLM calls.
2. **Latency**: Parsing is fast (~10-50ms). Adding an LLM call (~1-3s) would make session creation feel sluggish.
3. **Simplicity**: Cache invalidation is trivial with lazy evaluation — just check the fileHash on next request.

**Trade-off accepted**: First question per file version has ~1-3s additional latency for the enrichment call. Subsequent questions are instantaneous (cache hit).

### Why In-Memory Cache Only

**Decision**: SemanticEnrichment is cached in a `Dictionary` in memory, with no disk persistence.

**Rationale**:
1. **Alpha scale**: 5-50 users, handful of sessions each. Total cache size is measured in KB.
2. **Simplicity**: No serialization, no migration, no staleness concerns across app versions.
3. **Cache hits within a session are the common case**: Users typically ask multiple questions about the same file in one sitting.

**When to revisit**: When user count exceeds ~200 or when enrichment calls become a measurable cost line.

### Why Generation Counter Instead of Mutex

**Decision**: Coordinators use a `requestGeneration: UInt64` counter + `guard generation == requestGeneration` checks instead of mutex/actor isolation for request replacement.

**Rationale**:
1. **No lock contention**: The counter is checked, not locked. Multiple await points in the flow don't hold a lock.
2. **Natural cancellation**: New request → increment counter → cancel old task → old task's generation checks fail → old task exits silently.
3. **Proven pattern**: All three coordinators use this same approach consistently.

### Why Context Tiers Instead of Always Sending Full File

**Decision**: Four tiers of context (entity match → small file → local context → outline only) instead of always sending the full file.

**Rationale**:
1. **Token efficiency**: Tier 1 sends ~100-500 tokens of entity source vs ~500-10,000 tokens for full file.
2. **Focus**: The LLM explains better when it sees the specific entity containing the snippet, not a 1,000-line file.
3. **Large file handling**: Files >200 lines would overwhelm the LLM's context window. Tier 2.5 and 3 degrade gracefully.

### Why Four Relationship Kinds (Not More)

**Decision**: Start with `.calls`, `.conformsTo`, `.inherits`, `.owns`. No `.references`, `.creates`, `.delegates`, etc.

**Rationale**:
1. **Extractable from AST**: All four can be deterministically extracted from syntax trees. No type resolution needed (with the known Swift conformance ambiguity).
2. **High signal-to-noise**: These four cover the structural connections most relevant to understanding a file's role.
3. **Extensible**: `RelationshipKind` is an enum. Adding `.references` is a one-line addition + parser work.

### Why Manual DI

**Decision**: `AppDependencies` as a hand-wired root container. No DI framework (Swinject, Factory, etc.).

**Rationale**:
1. **Transparency**: All wiring is visible in one file. No runtime registration, no auto-injection magic.
2. **Compile-time safety**: Missing dependencies cause compile errors, not runtime crashes.
3. **Scale-appropriate**: ~15 services total. A DI framework adds complexity without proportional benefit.

### Why Single Enrichment Call for All Layers

**Decision**: One LLM call produces all four semantic layers (purpose, behavior, safety, design) via XML tags, instead of four separate calls.

**Rationale**:
1. **Latency**: One call (~1-3s) instead of four calls (~4-12s).
2. **Context sharing**: The LLM reasons about all layers simultaneously, producing more coherent understanding.
3. **Cache simplicity**: One cache entry per file version, not four.
4. **Independent parsing**: Each tag is extracted independently. If one is missing, the others still work.

---

## 15. Current Limitations

### Known Issues

1. **Swift conformance ambiguity**: SwiftSyntax lacks type resolution. On classes, all inheritance clause items are recorded as `.conformsTo` because the parser cannot distinguish superclass from protocol without full type checking. Structs and enums are unaffected (they can only conform, not inherit).

2. **Thin test coverage**: 13 test files exist but key services (ContextBuilderService, SessionResolver, SnippetHealthClassifier) lack unit tests. One pre-existing failure in `SelectionModeCoordinatorTests.swift:49` (`MockAIProvider` conformance).

3. **Sandbox disabled**: Re-enabling requires security-scoped bookmarks for file access. Not critical at alpha.

4. **No server-side request cancellation**: Client cancels `URLSession` task, but the server-side LLM call runs to completion. Wasted tokens on abandoned requests.

5. **No `os.Logger` in release builds**: Only server-side observability. No way to diagnose client issues in production builds.

6. **SQL grammar excluded**: Upstream tree-sitter SPM package issue prevents SQL parsing. SQL files get no entity extraction — only content heuristic detection for the `setPipeline` framework.

7. **Replace ⌘V targeting**: After clicking Replace in the improvement UI, the HUD panel may capture key window status, causing the simulated ⌘V paste to target the panel instead of the editor.

8. **Stale sandbox container**: `~/Library/Containers/com.decode.app/` from a previous sandboxed build can intercept UserDefaults. Must be manually deleted.

### Architectural Limitations

9. **Single-file understanding only**: File Intelligence understands files in isolation. Cross-file relationships (e.g., which files import this file, how a protocol is implemented across multiple files) are not tracked. This is the explicit motivation for Module Intelligence (Phase 2).

10. **No persistent enrichment cache**: Enrichment is lost on app restart. Not a problem at alpha scale but will matter when enrichment is used for more than prompt augmentation.

11. **No incremental parsing**: Full file re-parse on every modification. For large files, this could cause noticeable latency on rapid edits (e.g., continuous typing). Tree-sitter supports incremental parsing, but it's not implemented.

12. **Enrichment not cancellable**: If a user presses Double-tap Shift, the enrichment LLM call starts. If they press it again immediately, the generation counter cancels the outer task, but the inner `provider.generateCompletion()` call may still run to completion server-side.

---

## 16. Future Roadmap

### Phase 2: Module Intelligence

**Goal**: Understand how related files work together.

**Building blocks from Phase 1**:
- `Relationship` edges (`.calls`, `.conformsTo`, `.inherits`, `.owns`) provide cross-file link candidates when `targetName` resolves to an entity in a different file.
- `ImportDeclaration` provides explicit dependency declarations.
- `FileIdentity.role` and `FileIdentity.layer` enable module-level pattern detection (e.g., "this module has coordinators, services, and models — it follows a clean architecture pattern").

**Expected capabilities**:
- Cross-file dependency graph
- Module-level context in explanations ("this file is the coordinator for a module that also includes...")
- Impact analysis ("changing this protocol affects 5 implementors")

### Remaining Semantic Layers (Phase 1 Scope)

All semantic layers (Purpose, Behavior, Safety, Design) are implemented. The roadmap has shifted from completing Phase 1 layers to beginning Module Intelligence.

### Phase 3: Project Intelligence

Understand the whole codebase as architecture. Requires Module Intelligence as a foundation.

### Phase 4: Living Intelligence

Understanding that stays current as code evolves. Likely requires persistent enrichment cache, incremental parsing, and background re-enrichment.

---

## 17. Readiness Assessment

### File Intelligence: Complete

All five understanding layers are implemented and validated:

| Layer | Status | Source | Validation |
|-------|--------|--------|------------|
| Identity | Complete | Deterministic | Tested across 10 file types |
| Purpose | Complete | Deterministic + semantic | Tested across 10 file types |
| Behavior | Complete | Semantic (LLM) | Validated via enrichment pipeline |
| Safety | Complete | Semantic (LLM) | Validated via enrichment pipeline |
| Design | Complete | Semantic (LLM) | Validated via enrichment pipeline |

### Session Mode: Production-Ready for Alpha

| Capability | Status | Notes |
|------------|--------|-------|
| File opening / session creation | Working | Supports all 11 language grammars + unrecognized |
| AST parsing (Swift) | Working | SwiftSyntax 600.0.1 |
| AST parsing (9 languages) | Working | Tree-sitter with .scm queries |
| Entity extraction | Working | Classes, structs, enums, protocols, functions, methods, properties |
| Import extraction | Working | 6 language-specific parsers |
| Relationship extraction | Working | calls, conformsTo, inherits, owns |
| File watching | Working | Directory-level monitoring, atomic save support |
| Session resolution | Working | Multi-signal scoring, ambiguity detection |
| Context building (4 tiers) | Working | 63-97% token reduction |
| Code health classification | Working | Tree-sitter error analysis, full-file validation |
| Semantic enrichment | Working | Lazy, cached, single LLM call for 4 layers |
| Question-aware layer filtering | Working | Keyword + role-based routing |
| Explanation generation | Working | V7 adaptive prompt, 7 frameworks |
| Follow-up questions | Working | 3-message conversation, dedicated prompt |
| Code improvement | Working | Context-aware in Session Mode |
| Session dock | Working | Non-activating panel, magnification, pin/unpin |
| Quota enforcement | Working | 100 requests / 5-hour rolling window |
| Analytics | Working | Server-side token tracking, mode/tier/profile |

### What's Not Ready

| Item | Impact | Priority |
|------|--------|----------|
| Test coverage for core services | Risk of regression | High |
| MockAIProvider conformance failure | Cannot run coordinator tests | Medium |
| Server-side request cancellation | Wasted tokens | Low (alpha scale) |
| Persistent enrichment cache | Unnecessary at alpha | Low |
| SQL grammar support | Minor language gap | Low |

### Engineering Quality Assessment

- **Architecture**: Clean layered architecture with strict downward dependency. Protocols at domain layer. Manual DI.
- **Concurrency**: Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`). `@MainActor` isolation where needed. Generation-counter pattern for request replacement.
- **Error handling**: Graceful degradation throughout. Enrichment failure → deterministic fallback. Parse failure → empty result. Resolution failure → active session fallback.
- **Token efficiency**: Structured facts over raw source (90-95% reduction). Context tiers (63-97% reduction). Question-aware layer filtering (~20% system prompt reduction).
- **Code quality**: Consistent patterns across all three coordinators. Well-documented domain models. Clear separation of concerns.

---

*End of Technical Specification*
*Decode — Session Mode & File Intelligence Engineering Handbook v1.0*

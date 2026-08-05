# Visual Context — Technical Architecture

**Status**: Final design (implementation-ready)
**Date**: 2026-08-01
**Scope**: Selection Mode, Screenshot Mode only
**Revision**: 3 — final refinement

---

## 1. Executive Summary

Visual Context adds an optional **evidence compression stage** to the Selection and Screenshot Mode pipelines. It captures a screenshot of the user's working area and uses a vision-capable LLM to extract a compact set of contextual observations (~80-120 tokens) that improve the subsequent explanation.

**Core design principle**: Visual Context is an evidence extractor, not an explainer. It compresses a visual scene into the smallest possible set of high-value factual observations that make the next reasoning stage better. It never explains, reviews, teaches, or speculates.

The feature is off by default. When disabled, zero code paths change. When enabled, a vision extraction stage runs before the explanation, producing evidence that is injected into the explanation prompt. Graceful degradation: any vision failure → proceed without visual context → identical to feature disabled.

---

## 2. High-Level Pipeline

### 2.1 Selection Mode (Visual Context ON)

```
Double-tap Control
    │
    ├─ AccessibilityCapture → selected text          (existing, parallel)
    ├─ ScreenCaptureService → focused window image   (NEW, parallel)
    │
    ▼
VisualContextExtractor                               (NEW)
    │  Input:  CGImage only (no metadata)
    │  Output: VisualContext ([VisualEvidence], ~80-120 tokens)
    │
    ▼
User message assembly
    │  evidence block + selected text                 (MODIFIED)
    │
    ▼
aiProvider.streamChat()  →  HUD                      (existing, unchanged)
```

### 2.2 Screenshot Mode (Visual Context ON)

```
Double-tap Option → ScreenCaptureService → CGImage   (existing)
    │
    ├─ VisionOCRService → OCR text                   (existing, parallel)
    ├─ VisualContextExtractor → VisualContext         (NEW, parallel)
    │
    ▼
User message assembly
    │  evidence block + OCR text                      (MODIFIED)
    │
    ▼
aiProvider.streamChat()  →  HUD                      (existing, unchanged)
```

### 2.3 When OFF

Both pipelines execute exactly as today. No capture, no vision call, no prompt modification. The toggle check is a single `if` at the coordinator level.

---

## 3. Component Diagram

```
┌───────────────────────────────────────────────────────────┐
│                      AppDependencies                       │
│                                                            │
│  ┌────────────────────┐      ┌──────────────────────┐      │
│  │ SelectionMode      │      │ ScreenshotMode       │      │
│  │ Coordinator        │      │ Coordinator           │      │
│  │                    │      │                       │      │
│  │ AccessibilityCapture│      │ ScreenCaptureService  │      │
│  │ ScreenCaptureService│      │ VisionOCRService      │      │
│  └─────────┬──────────┘      └───────────┬───────────┘      │
│            │                             │                  │
│            └──────────┬──────────────────┘                  │
│                       ▼                                     │
│         ┌───────────────────────────┐                       │
│         │  VisualContextExtractor   │ (NEW)                 │
│         │                           │                       │
│         │  In:  CGImage             │                       │
│         │  Out: VisualContext?      │                       │
│         │       [VisualEvidence]    │                       │
│         │                           │                       │
│         │  Uses: AIProviderProtocol │                       │
│         │        (vision call)      │                       │
│         └───────────┬───────────────┘                       │
│                     ▼                                       │
│         ┌───────────────────────────┐                       │
│         │  User message assembly    │                       │
│         │  evidence + code/OCR      │                       │
│         └───────────┬───────────────┘                       │
│                     ▼                                       │
│         ┌───────────────────────────┐                       │
│         │  aiProvider.streamChat()  │ (existing)            │
│         └───────────┬───────────────┘                       │
│                     ▼                                       │
│         ┌───────────────────────────┐                       │
│         │  FloatingExplanationHUD   │ (existing, unchanged) │
│         └───────────────────────────┘                       │
└───────────────────────────────────────────────────────────┘
```

---

## 4. New Components

### 4.1 VisualContextExtractor

**Layer**: Application
**File**: `Decode/Application/VisualContextExtractor.swift`

A stateless service that takes a `CGImage` and returns `VisualContext?`. Encapsulates:
1. CGImage → JPEG Data conversion
2. Vision LLM call via `AIProviderProtocol`
3. Response parsing (line-based `key: value` → `[VisualEvidence]`)
4. Response validation (length, emptiness)

Shared by both coordinators (same extraction logic). Analogous to `VisionOCRService` — a small, focused service called by coordinators.

**Protocol**: `VisualContextExtracting` — for testability, consistent with the existing `ScreenCaptureProtocol` / `OCRServiceProtocol` pattern.

```swift
protocol VisualContextExtracting: Sendable {
    func extract(from image: CGImage) async -> VisualContext?
}
```

Returns nil on any failure. Coordinator treats nil as "proceed without visual context."

### 4.2 VisualContext (Domain Model)

**Layer**: Domain
**File**: `Decode/Domain/Models/VisualContext.swift`

See Section 6.

### 4.3 AIProviderProtocol: New Method

**Layer**: Domain (protocol), Infrastructure (implementation)

A new method for non-streaming multimodal completion. See Section 5.

---

## 5. Vision Extraction Contract

### 5.1 Client-Side: New AIProviderProtocol Method

```swift
protocol AIProviderProtocol: Sendable {
    // ... existing methods unchanged ...

    /// Generate a non-streaming completion from an image and a text prompt.
    ///
    /// Used by Visual Context extraction. Non-streaming because the output
    /// is short structured evidence (~100 tokens), not a user-facing narrative.
    func generateVisionCompletion(
        imageData: Data,
        prompt: String,
        mode: String?
    ) async throws -> String
}

// Default: providers that don't support vision fail explicitly.
extension AIProviderProtocol {
    func generateVisionCompletion(
        imageData: Data, prompt: String, mode: String?
    ) async throws -> String {
        throw AIProviderError.unsupportedCapability("Vision")
    }
}
```

**Why a dedicated method** (not extending `generateCompletion` or `streamChat`):
- `generateCompletion(userContent:systemPrompt:mode:)` takes `String` content. Adding `imageData: Data?` would either pollute every call site or require overload disambiguation.
- Non-streaming: vision output is ~100 tokens of structured evidence. Streaming adds complexity with no benefit — the user never sees this output.
- `Data` not `CGImage`: The protocol is in the Domain layer. `Data` (JPEG bytes) is platform-portable; `CGImage` leaks CoreGraphics.

### 5.2 Backend: New Vision Endpoint

```
POST /api/gateway/vision
```

**Request**:
```json
{
    "image_base64": "<base64-encoded JPEG>",
    "prompt": "<extraction prompt>",
    "mode": "selection_vision" | "screenshot_vision",
    "max_tokens": 256
}
```

**Response**:
```json
{
    "content": "<evidence text>"
}
```

**Why a separate endpoint** (not extending `/api/gateway/chat`):
1. The existing `ChatMessage` model uses `content: str`. Multimodal content blocks (Anthropic's `[{type: "image"}, {type: "text"}]`) require a structurally different message payload.
2. Separate endpoints allow routing vision requests to a different model (e.g., a fast, cheap vision model) without affecting explanation model configuration.
3. Request logging tracks vision calls distinctly — different cost profile, different latency expectations.

**Provider routing**: The Multi-Provider AI Platform already supports capability-based routing. Vision could be registered as a capability in `KnowledgeCapabilityResolver`, or the backend can route based on the `/vision` endpoint directly. For v1, backend-side routing is simpler — the endpoint calls a vision-capable model without needing the full capability resolver.

### 5.3 Token Budget

```swift
enum AILimits {
    /// Maximum tokens the vision model may generate.
    /// The extraction prompt targets 80-120 tokens. Hard cap at 256
    /// prevents runaway generation while allowing headroom.
    static let maxVisionResponseTokens = 256
    
    /// Maximum JPEG bytes sent to the vision endpoint.
    static let maxVisionImageBytes = 800 * 1024  // 800 KB
    
    /// Timeout for vision extraction (seconds).
    /// Shorter than explanation timeout — visual context is optional enrichment.
    static let visionTimeoutSeconds: TimeInterval = 10
}
```

---

## 6. Visual Context Output Schema

### 6.1 Critical Design Constraint: Evidence Compression

The vision stage is an **evidence compression stage**. Its output budget is:

| Constraint | Value |
|------------|-------|
| Target output | 80–120 tokens |
| Preferred output | ~100 tokens |
| Hard maximum | 200 tokens (exceptional) |
| `max_tokens` sent to model | 256 (headroom) |

### 6.2 Engineering Rule: Observability Only

**Visual Context may contain only directly observable information from the image.**

This is a non-negotiable architectural invariant, not a prompt suggestion:

- **No inference.** Do not conclude that code "likely uses dependency injection" from a constructor signature.
- **No speculation.** Do not guess what a partially visible function does.
- **No architectural conclusions.** Do not assess patterns, quality, or design decisions.
- **No explanation.** Do not describe what the code does or why it exists.
- **No code reproduction.** Do not dump visible code blocks. Summarize structure.

The vision model must report only what it can **see** — file names, type signatures, import statements, visible diagnostics, editor identity. If it cannot see something, it must not report it.

This rule is enforced at three levels:
1. **Prompt**: Explicit prohibitions in the extraction prompt (Section 7).
2. **Token budget**: `max_tokens: 256` with 80-120 target makes verbose or narrative output structurally impossible.
3. **Monitoring**: `vision_prompt_version` tracking (Section 11) enables prompt refinement when violations are detected.

### 6.3 Domain Model

```swift
/// A single item of visual evidence extracted from a screenshot.
///
/// Each item is a typed observation: a category (`type`) and a concise
/// factual value (`content`). The type is an open string — not an enum —
/// so new observation categories emerge from prompt evolution without
/// requiring schema changes.
struct VisualEvidence: Sendable, Codable, Equatable {

    /// The observation category.
    /// Well-known types: "file", "lang", "editor", "contains", "imports",
    /// "warning", "error", "near", "visible".
    /// New types can be introduced via prompt changes — no code changes.
    let type: String

    /// The factual content of the observation.
    /// Must be directly observable from the image. Never inferred or speculated.
    let content: String
}

/// Compact contextual evidence extracted from a screenshot of the user's
/// working area. Produced by the vision extraction stage, consumed by the
/// explanation prompt assembly.
///
/// Contains an ordered list of typed evidence items. The total output is
/// ~80-120 tokens — aggressively compressed for maximum information density.
struct VisualContext: Sendable, Codable, Equatable {

    /// Ordered evidence items, highest-priority first.
    let items: [VisualEvidence]

    /// Whether the extraction produced any meaningful content.
    var isEmpty: Bool { items.isEmpty }

    /// Format evidence for injection into the explanation user message.
    /// Produces a compact "type: content" block, one line per item.
    func formatted() -> String {
        items.map { "\($0.type): \($0.content)" }.joined(separator: "\n")
    }
}
```

### 6.4 Why `[VisualEvidence]` (Not Typed Fields, Not Raw String)

The v1 design proposed 6 rigid fields (`surroundingCode`, `fileName`, etc.). The v2 design proposed a single `evidence: String`. This final design uses a typed list — a middle ground that is both structured and extensible.

**Why not 6 typed fields (v1)**:

1. **Token overhead**: XML tags for 6 fields consume ~30 tokens (25-37% of the budget) on structure alone.
2. **Rigid schema**: Adding new observation types (debugger state, git indicators) requires new Swift fields, new parsing, new formatting. Every evolution is a code change.
3. **`surroundingCode` was a trap**: A dedicated field invited the model to dump code blocks.

**Why not a raw `String` (v2)**:

1. **No analytics granularity**: Can't count how often "file" vs "warning" observations appear without server-side text parsing — fragile and ad-hoc.
2. **No filtering**: Can't programmatically drop low-value observations (e.g., "editor") if evidence shows they don't help.
3. **No utilization tracking**: Can't measure which evidence types the explanation LLM actually used (Section 11.5).

**Why `[VisualEvidence]` (v3)**:

1. **Extensible**: `type` is an open `String`, not a closed enum. New observation categories (e.g., `"debugger"`, `"git"`, `"test"`) emerge from prompt changes — zero schema changes, zero code changes to `VisualContext`.
2. **Structured for analytics**: Each item has a discrete type, enabling type-frequency analysis, utilization tracking, and quality measurement without text parsing.
3. **Token-efficient**: The wire format is still `key: value` lines. Parsing splits each line at the first `:`. The struct adds no overhead to the LLM interaction.
4. **Filterable**: If analytics reveals that certain evidence types degrade explanations, the extractor can filter them before returning — without changing the domain model.
5. **Lightweight**: Two fields per item (`type` + `content`). No optionality, no nesting, no metadata. The model is ~25 lines including documentation.

### 6.5 Wire Format and Parsing

The vision LLM returns `key: value` lines (same as v2). `VisualContextExtractor` parses each line into a `VisualEvidence` item:

```swift
// Parsing logic in VisualContextExtractor:
func parseEvidence(_ rawOutput: String) -> [VisualEvidence] {
    rawOutput
        .split(separator: "\n")
        .compactMap { line -> VisualEvidence? in
            let str = line.trimmingCharacters(in: .whitespaces)
            guard let colonIndex = str.firstIndex(of: ":") else { return nil }
            let type = str[str.startIndex..<colonIndex]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let content = str[str.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces)
            guard !type.isEmpty, !content.isEmpty else { return nil }
            return VisualEvidence(type: type, content: content)
        }
}
```

No XML. No JSON. Just line splitting at the first colon. Malformed lines are silently dropped — partial output degrades gracefully.

### 6.6 Example

Vision model output:
```
file: UserService.swift
lang: Swift
editor: Xcode
contains: class UserService { fetchUser(id:), deleteUser(id:), updateUser(_:) }
imports: Foundation, GRDB
warning: line 23 — unused result of fetchUser
near: protocol UserRepository defined above
```

Parsed into:
```swift
VisualContext(items: [
    VisualEvidence(type: "file",     content: "UserService.swift"),
    VisualEvidence(type: "lang",     content: "Swift"),
    VisualEvidence(type: "editor",   content: "Xcode"),
    VisualEvidence(type: "contains", content: "class UserService { fetchUser(id:), deleteUser(id:), updateUser(_:) }"),
    VisualEvidence(type: "imports",  content: "Foundation, GRDB"),
    VisualEvidence(type: "warning",  content: "line 23 — unused result of fetchUser"),
    VisualEvidence(type: "near",     content: "protocol UserRepository defined above"),
])
```

~45 tokens. 7 items. Dense, typed, extensible.

### 6.7 Schema Evolution

| Change | Code Impact |
|--------|-------------|
| Add new observation type (e.g., `"debugger"`) | Prompt change only. `VisualEvidence.type` is an open string. |
| Remove low-value type (e.g., `"editor"`) | Prompt change, or filter in extractor. Domain model unchanged. |
| Track type frequency in analytics | Query `items` array. No text parsing. |
| Filter specific types before injection | `items.filter { $0.type != "editor" }`. Trivial. |
| Measure utilization per type | Compare each item against explanation text (Section 11.5). |

---

## 7. Vision Extraction Prompt

### 7.1 Extraction Prompt (v1)

The prompt is versioned. The version identifier (`v1`) is tracked in analytics via `vision_prompt_version` (Section 11.2) so quality experiments across prompt iterations are measurable.

```
Extract contextual evidence from this screenshot of a developer's screen.
The developer has selected/highlighted code. Your job is to identify what
SURROUNDS the selection that would help someone understand it better.

Return ONLY directly observable facts. One per line, as "key: value".

Useful keys: file, lang, editor, contains, imports, warning, error, near, visible

Budget: ~100 tokens. Be extremely concise.

Rules:
- Report ONLY what is directly visible on screen. Zero inference. Zero speculation.
- Never reproduce code blocks. Summarize structure: "contains: class X { methodA(), methodB() }"
- Never explain, review, or summarize the selected/highlighted code.
- Never provide commentary, opinions, architectural conclusions, or teaching.
- Never guess what partially visible code does or what off-screen code might contain.
- Omit observations with no explanatory value.
- If a key has no visible evidence, omit it entirely.
- Priority: file identity > surrounding structure > diagnostics > imports > other
```

### 7.2 Prompt Design Rationale

1. **Aggressive compression**: "~100 tokens" and "Be extremely concise" enforce the budget. The model treats this as a hard constraint.

2. **Anti-patterns as rules**: Explicit prohibitions ("Never reproduce code blocks", "Never explain") prevent the most common vision model failure modes.

3. **Priority ordering**: When the budget is tight, the model knows to prioritize file identity over imports, and structure over diagnostics.

4. **"key: value" format**: Simple, no XML overhead, easy for the explanation LLM to read. Extensible — new keys require zero code changes.

5. **"contains" pattern**: Instead of dumping code, the model summarizes structure: `contains: class UserService { fetchUser(), deleteUser() }`. This captures the same information in ~10 tokens instead of ~100.

6. **No metadata input**: The prompt receives ONLY the image. No selected text, no coordinates, no filename. The vision model works from the visual scene alone. The selected code is already highlighted in the editor — the model can see it.

### 7.3 Token Budget Enforcement

The `max_tokens` parameter (256) provides a hard ceiling. The prompt targets 80-120 tokens. `VisualContextExtractor` validates after parsing:
1. Parse all lines into `[VisualEvidence]` items.
2. If total formatted output exceeds 200 tokens (~800 characters), drop items from the end (lowest priority) until within budget.
3. Empty or unparseable lines are silently dropped during parsing.

---

## 8. Explanation Stage: How Visual Context Is Consumed

### 8.1 Injection Point: User Message

Visual Context is injected into the **user message**, not the system prompt.

**Current user message** (Selection Mode):
```
<selected text>
```

**Modified user message** (when Visual Context is present):
```
[Context]
file: UserService.swift
lang: Swift
contains: class UserService { fetchUser(id:), deleteUser(id:) }
imports: Foundation, GRDB
warning: line 23 — unused result of fetchUser
[/Context]

<selected text>
```

When Visual Context is absent (feature off, extraction failed, or empty result):
```
<selected text>
```

Identical to current behavior. Zero change.

### 8.2 Why User Message, Not System Prompt

1. **System prompt is frozen** (ExplanationFramework V7). Conditional modification introduces branching complexity in a frozen component.
2. **Visual Context is instance data**, not behavioral instructions. It varies per request, like the selected code.
3. **Follow-up preservation**: The user message enters conversation history via `FollowUpContext.sourceContent`. Follow-ups automatically see the visual context. If it were in the system prompt, follow-ups (which use `followUpSystemPrompt`) would lose it.
4. **Consistency**: The explanation LLM already handles variable-length user input. An additional ~100 tokens of context is within normal variance.

### 8.3 Context Assembly Integration

Selection and Screenshot modes use direct string building in the coordinator. Visual Context integrates at the same level:

```swift
// In coordinator, after extraction:
let userMessage: String
if let vc = visualContext, !vc.isEmpty {
    userMessage = "[Context]\n\(vc.formatted())\n[/Context]\n\n\(text)"
} else {
    userMessage = text
}
let messages = [AIMessage(role: .user, content: userMessage)]
```

This is consistent with how these coordinators work today: the system prompt is built via `buildSystemPrompt()` + framework detection + representation guidance + working memory. The user message is the primary content. Visual Context adds evidence to the user message.

**Architectural consistency with the pipeline model**: In the understanding pipeline (Session Mode), the pattern is: produce evidence → assemble context → consume. Visual Context follows the same conceptual pattern for Selection/Screenshot modes:
- **Produce**: `VisualContextExtractor` produces structured evidence from the visual scene
- **Assemble**: Coordinator combines evidence with selected code/OCR text into the user message
- **Consume**: `ExplanationFramework` (via `streamChat()`) consumes the assembled context

The difference is that Selection/Screenshot use coordinator-level assembly (simple string building) while Session Mode uses the understanding pipeline (structured evidence retrieval and context assembly). This difference is intentional — Selection/Screenshot are simpler modes that don't need the full pipeline. Visual Context respects this simplicity.

---

## 9. Follow-Up and Improve Interaction

### 9.1 Follow-Up Questions

When Visual Context is present, the user message in `FollowUpContext.sourceContent` includes the `[Context]...[/Context]` block. Follow-up conversations automatically see it:

```
User: [Context]...[/Context] <selected code>
Assistant: <explanation>
User: <follow-up question>
```

No changes to `FollowUpContext` structure or follow-up flow. The visual evidence is naturally part of the conversation history.

### 9.2 Improve Code

`FollowUpContext.originalCode` stores the raw selected text (not the assembled user message). Visual Context is NOT injected into improvement prompts — `ImprovementService` needs only the code to suggest improvements, not surrounding context.

No changes to `ImprovementService`.

---

## 10. UI Architecture

### 10.1 Toggle

Add a toggle in the same settings area as DSA Mode and Virtual Session:

```swift
Toggle("Visual Context", isOn: $visualContextEnabled)
    .help("Capture your screen to provide richer code explanations")
```

**Product-facing name**: **"Visual Context"** — concise, descriptive, fits existing toggle naming.

### 10.2 State Management

Follow the `dsaModeEnabled` pattern (simplest — no service lifecycle):

```swift
// In AppDependencies:
var visualContextEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "visualContextEnabled") }
    set { UserDefaults.standard.set(newValue, forKey: "visualContextEnabled") }
}
```

The toggle is checked at call time in each coordinator. No service initialization or teardown on toggle change.

### 10.3 Persistence

`UserDefaults`, key `"visualContextEnabled"`, default `false`. No migration.

### 10.4 HUD Changes

**None for v1**. The HUD displays whatever the explanation LLM returns. Visual Context affects input, not output format. Tag parser, rendering, and HUD layout are unchanged.

### 10.5 First-Run Disclosure

When the user first enables Visual Context, show a one-time alert:

> "Visual Context captures a screenshot of your working area and sends it to Decode's AI service to understand your surrounding code. The screenshot is not stored. Disable this if you work with sensitive information on screen."

Tracked via `UserDefaults` key `"visualContextDisclosureShown"`.

---

## 11. Analytics Architecture

### 11.1 Product Validation Philosophy

Visual Context is an optional feature explicitly designed for validation. Analytics must answer: **does Visual Context actually improve user experience?** Cost and performance tracking alone are insufficient — we need quality signals.

### 11.2 Request Analytics

**Vision request logging** — each vision extraction is a separate LLM call, logged as a distinct request:

| Field | Type | Value |
|-------|------|-------|
| `mode` | `str` | `"selection_vision"` or `"screenshot_vision"` |
| `success` | `bool` | Whether extraction succeeded |
| `latency_ms` | `int` | Vision call round-trip time |
| `prompt_tokens` / `completion_tokens` | `int` | Vision model token usage |
| `error_type` | `str?` | On failure: timeout, network, provider error |
| `vision_prompt_version` | `str` | Version of the extraction prompt used (e.g., `"v1"`) |
| `evidence_item_count` | `int?` | Number of `VisualEvidence` items returned (on success) |
| `evidence_types` | `str?` | Comma-separated list of evidence types returned (e.g., `"file,lang,contains,imports"`) |

**Explanation request fields** — new nullable columns on `request_logs`:

| Field | Type | Description |
|-------|------|-------------|
| `visual_context` | `bool?` | Whether Visual Context evidence was injected into this explanation |
| `visual_context_tokens` | `int?` | Character count of the injected evidence block |
| `vision_prompt_version` | `str?` | Version of the extraction prompt that produced the evidence |
| `explanation_prompt_version` | `str?` | Version of the explanation prompt (e.g., `"v7"`, `"dsa_v1"`) |

Null = feature didn't exist when logged.

**Prompt versioning rationale**: Both prompt versions are logged on every request — vision and explanation — so that quality metrics can be segmented by prompt iteration. When a prompt is refined, the version increments. All existing metrics (follow-up rate, regenerate rate, utilization) can then be compared across prompt versions, enabling controlled quality experiments.

### 11.3 Product Analytics Events

| Event | When | Metadata |
|-------|------|----------|
| `visual_context_enabled` | User enables toggle | — |
| `visual_context_disabled` | User disables toggle | `{"days_enabled": N}` |

### 11.4 Quality Validation Metrics

These metrics answer whether Visual Context improves user experience. All are computed server-side from existing + new analytics data.

**Adoption & Retention**:

| Metric | Computation | Signal |
|--------|-------------|--------|
| **Feature adoption rate** | Users who enable VC / total active users | Market interest |
| **Toggle retention** | Users who keep VC enabled after 7 days / users who enabled it | Perceived value |
| **Disable-after-try rate** | Users who disable within 24h of enabling | Negative signal — likely latency |
| **Re-enable rate** | Users who disable then re-enable later | Curiosity vs commitment |

**Quality Proxy Metrics** (A/B: VC-on vs VC-off per user):

| Metric | Computation | Signal |
|--------|-------------|--------|
| **Follow-up rate** | Follow-up requests / explanation requests, VC-on vs VC-off | Lower follow-up = better first explanation |
| **Follow-up depth** | Average follow-up count per explanation chain | Fewer follow-ups = more complete first answer |
| **Improve rate** | Improve requests / selection explanation requests | May increase (better context → more actionable improvements) |
| **Session length** | Time from explanation to HUD dismiss | Longer = more engaged reading |
| **Regenerate rate** | Count of re-triggered explanations (same text, short interval) | Lower = satisfactory first explanation |

**Cost & Performance**:

| Metric | Computation | Signal |
|--------|-------------|--------|
| **Vision latency (p50, p95)** | Percentiles of `latency_ms` for `*_vision` requests | Latency budget compliance |
| **Total latency impact** | Explanation latency (VC-on) − explanation latency (VC-off) | User-perceived slowdown |
| **Vision cost per explanation** | Average `total_tokens` for vision requests | Cost to provide feature |
| **Explanation token increase** | Average `prompt_tokens` increase when `visual_context = true` | Marginal cost of injecting evidence |
| **Vision failure rate** | Failed `*_vision` / total `*_vision` requests | Reliability |
| **Empty evidence rate** | Successful vision extractions that produce empty/useless context | Wasted cost |

**Engagement (Higher-Level)**:

| Metric | Computation | Signal |
|--------|-------------|--------|
| **Explanations per session (VC-on vs off)** | Count of explanation requests per user session | More usage = more value |
| **Mode distribution shift** | Selection vs Screenshot usage before/after VC enable | Feature may attract more Selection Mode usage |
| **Improve copy/replace rate** | `improve_copy` + `improve_replace` events, VC-on vs off | Actionability of improvements |

### 11.5 Visual Context Utilization

**Purpose**: Measure whether the explanation stage actually **used** the Visual Context evidence. A high extraction success rate with low utilization means the vision call is wasted cost — the evidence doesn't influence the explanation.

**Mechanism**: After the explanation is generated, compare each `VisualEvidence` item against the explanation text. An evidence item is "utilized" if its content (or a semantically equivalent reference) appears in the explanation.

**Implementation** (server-side, computed asynchronously after explanation completes):

```python
def compute_utilization(evidence_items: list[dict], explanation: str) -> dict:
    """Compute per-item and aggregate utilization."""
    utilized = []
    for item in evidence_items:
        # Check if the explanation references this evidence item.
        # Heuristic: does the explanation contain the item's content
        # or key identifying tokens from it?
        content = item["content"]
        # For "file" type: check if filename appears in explanation
        # For "contains": check if type/method names appear
        # For "warning"/"error": check if diagnostic is referenced
        tokens = extract_key_tokens(item["type"], content)
        if any(token.lower() in explanation.lower() for token in tokens):
            utilized.append(item["type"])
    return {
        "utilized_types": utilized,
        "utilized_count": len(utilized),
        "total_count": len(evidence_items),
        "utilization_rate": len(utilized) / len(evidence_items) if evidence_items else 0,
    }
```

**Tracked as metadata** on the explanation request log entry:

| Field | Type | Description |
|-------|------|-------------|
| `vc_utilization_rate` | `float?` | Fraction of evidence items referenced in the explanation (0.0–1.0) |
| `vc_utilized_types` | `str?` | Comma-separated types that were utilized (e.g., `"file,contains,warning"`) |

**What utilization tells us**:

| Utilization Rate | Interpretation | Action |
|-----------------|----------------|--------|
| >70% | Evidence is highly relevant. Vision call provides real value. | Confirm feature value. |
| 30-70% | Mixed. Some evidence types are useful, others ignored. | Refine prompt to prioritize high-utilization types. |
| <30% | Evidence is mostly ignored. Vision call is wasted cost. | Investigate: is the evidence low-quality, or does the explanation model not need it? |
| 0% consistently | Complete waste. The explanation LLM never references visual context. | Reconsider the feature. |

**Per-type utilization** (from `vc_utilized_types`) reveals which evidence categories are most valuable. If "file" and "contains" are always utilized but "editor" and "lang" never are, the extraction prompt can be refined to drop the low-value types — reducing token usage further.

### 11.6 Recommended Dashboard View

Add a "Visual Context" section to the admin dashboard:
- Toggle adoption funnel (enabled → retained → disabled)
- Side-by-side quality metrics: VC-on vs VC-off
- Vision latency and failure rate time series
- Cost waterfall: vision tokens + explanation token increase

---

## 12. Failure Handling

### 12.1 Design Principle

Visual Context is **optional enrichment**. Any failure → proceed without visual context → identical to feature disabled. The user never sees a vision error.

### 12.2 Failure Matrix

| Scenario | Handling | User Impact |
|----------|----------|-------------|
| Screen Recording permission denied | `captureWorkingArea()` returns nil → skip VC | Normal explanation, no delay |
| Image too large (> `maxVisionImageBytes`) | Resize or skip | Normal explanation |
| Vision LLM fails (network, 500, 429) | `extract()` returns nil | Normal explanation, wasted ~2-5s |
| Vision LLM times out (> 10s) | Task cancelled → nil | Normal explanation after 10s delay |
| Vision LLM returns empty/whitespace | No items parsed → `VisualContext.isEmpty` → skip injection | Normal explanation |
| Vision LLM returns >200 tokens | Drop lowest-priority items until within budget | Evidence injected (truncated) |
| Vision LLM returns unparseable output | No valid `key: value` lines → empty items → skip | Normal explanation |
| AI provider doesn't support vision | Default extension throws → caught → nil | Normal explanation |
| Explanation LLM fails after successful vision | Existing coordinator error handling | Error in HUD (existing behavior) |

### 12.3 Wasted Latency on Vision Failure

The worst user-visible failure mode is: vision call takes 5-10 seconds, then fails, and only THEN does the explanation start. The user waited extra time for nothing.

**Mitigation**: The 10-second timeout (`AILimits.visionTimeoutSeconds`) bounds this cost. For Selection Mode, vision extraction runs in parallel with text capture where possible. For Screenshot Mode, vision runs in parallel with OCR — a vision failure adds zero delay.

### 12.4 Logging

```swift
#if DEBUG
print("[VisualContext] extraction failed: \(error.localizedDescription)")
#endif
```

Plus server-side request log with `success: false` and `error_type`.

---

## 13. Security and Privacy Considerations

### 13.1 Primary Threat: Sensitive Content in Screenshots

Screenshots may capture passwords, API keys, private messages, financial data, or proprietary code visible on screen.

### 13.2 Mitigations

1. **Selection Mode**: Capture the focused window only, not the full screen. This limits exposure to content in the same window as the code.

2. **Screenshot Mode**: Reuses the same image the user already selected for OCR. No additional capture.

3. **Ephemeral image handling**: `CGImage` exists in memory only during the vision extraction call. Never written to disk. Never cached. Freed by ARC after the call completes. Consistent with existing OCR pattern.

4. **Backend: no image persistence**: The backend forwards the image to the vision model and discards it. No logging, no storage, no retention.

5. **User opt-in**: Feature is off by default. First-run disclosure on enable (Section 10.5).

6. **JPEG compression**: Images are compressed before transmission, slightly degrading fidelity of sensitive text.

### 13.3 Permission Requirements

| Mode | Without Visual Context | With Visual Context |
|------|----------------------|-------------------|
| Selection | Accessibility | Accessibility + **Screen Recording** (new) |
| Screenshot | Screen Recording | Screen Recording (unchanged) |

**Selection Mode adds Screen Recording permission**. This is requested only when the user first enables Visual Context — not at app startup, and not for users who never enable the feature. If permission is denied, the toggle remains enabled but visual context silently returns nil (graceful degradation).

---

## 14. Performance Considerations

### 14.1 Latency Budget

| Stage | Current | With Visual Context |
|-------|---------|-------------------|
| Text capture / OCR | ~100-500ms | Unchanged |
| **Vision extraction** | — | **~2-4s** (new) |
| Explanation LLM | ~3-8s | ~3-9s (~100 extra tokens in prompt) |
| **Total** | **~3-9s** | **~5-13s** |

### 14.2 Latency Mitigations

1. **Parallelization**:
   - **Selection Mode**: Text capture (AX API) and screenshot capture (ScreenCaptureKit) run in parallel via `async let`. Vision extraction starts as soon as the image is available, overlapping with prompt assembly.
   - **Screenshot Mode**: OCR (local, Apple Vision) and vision extraction (network) run in parallel on the same image. Vision is often "free" if it completes during or before OCR.

2. **Small output budget**: 80-120 tokens generates in ~0.3-0.5s (Haiku). The bottleneck is image upload + model processing, not token generation.

3. **Image optimization**: Resize to max 1536px wide, JPEG quality 0.75. A typical code editor screenshot is ~200-400 KB after compression.

4. **Fast vision model**: Use a fast, cheap model for extraction (Haiku with vision). The task is simple pattern recognition, not complex reasoning.

5. **Tight timeout**: 10 seconds. If the vision call hasn't completed, proceed without it.

### 14.3 Cost Impact (Revised for Tight Token Budget)

| Component | Tokens | Est. Cost (Haiku) |
|-----------|--------|-------------------|
| Vision input: image | ~800-1500 | ~$0.0008-0.0015 |
| Vision input: prompt | ~150 | ~$0.00015 |
| Vision output | ~100 | ~$0.0001 |
| Explanation input increase | ~100 extra tokens | ~$0.0001 |
| **Per-request overhead** | | **~$0.001-0.002** |

~50% cheaper than the v1 estimate, because the tight output budget reduces both vision output tokens and the evidence block injected into the explanation prompt.

At alpha scale (5-50 users, 100 requests/5h quota): ~$0.10-0.20 per quota window per user.

### 14.4 Quota Impact

Vision extraction is exempt from the existing 100-request quota, consistent with how semantic enrichment is handled. Vision usage is tracked separately via analytics.

---

## 15. Future Extensibility

### 15.1 Better Vision Models

The backend vision endpoint can route to any vision-capable model. Switching models requires only changing an environment variable — no client changes. The Multi-Provider AI Platform already supports multiple providers.

### 15.2 Local Vision Models

Replace `LLMVisualContextExtractor` (the concrete implementation) with a local inference version using Core ML or similar. The `VisualContextExtracting` protocol is unchanged. This would eliminate the privacy concern and network latency.

### 15.3 Richer Evidence

`VisualEvidence.type` is an open string, not a closed enum. Adding new observation types (debugger state, git indicators, test results) requires only updating the extraction prompt. The parser, domain model, formatting, and injection are all type-agnostic — zero code changes.

### 15.4 Session Mode

Intentionally excluded. Session Mode has workspace intelligence, file intelligence, semantic enrichment, and context tiers. If evidence shows visual context adds value even with workspace context, the same extractor and model can be reused — only the coordinator integration point changes.

### 15.5 Single Multimodal Stage

The two-stage design (extract → explain) can evolve into a single-stage design (image + code → explain) by having the coordinator send the image directly to a multimodal explanation model, bypassing the extractor. The `VisualContextExtracting` protocol allows this: a future implementation could return nil while injecting the image into the explanation call via a different path. However, this requires the explanation model to be vision-capable, which creates a model dependency.

---

## 16. Risks

### 16.1 Latency Remains the Primary Risk

Even with parallelization, vision extraction adds 2-4 seconds to Selection Mode (where text capture is fast). Users who trigger Selection Mode expect ~3-5 second responses. Doubling this to ~7-10 seconds may cause users to disable the feature before appreciating the quality improvement.

**Tracking**: Disable-after-try rate (Section 11.4). If > 40% of users disable within 24 hours, investigate latency as the cause.

### 16.2 Token Budget Enforcement Is Prompt-Dependent

The 80-120 token target is enforced by prompt instructions, not by the protocol. Vision models may occasionally produce verbose output despite the "~100 tokens" instruction. The `max_tokens: 256` hard cap prevents runaway generation, but a 250-token response is still 2.5x the target.

**Mitigation**: `VisualContextExtractor` validates output length. If the response exceeds 200 tokens, truncate at the last complete line boundary. Log truncation events for prompt refinement.

### 16.3 Vision Extraction Quality Is Unproven

The hypothesis that a vision model can reliably extract useful contextual observations from code editor screenshots is untested. Failure modes:
- **Dark themes with low contrast** — syntax highlighting hard to parse
- **Small font sizes** — code illegible at compressed resolution
- **Split editors** — model extracts from wrong panel
- **Non-code panels** — terminal, file tree, docs injected as noise

**Recommendation**: Before implementation, test the extraction prompt against 20-30 real screenshots from different editors, themes, and font sizes. Measure: (a) extraction accuracy, (b) output token count, (c) evidence value.

### 16.4 Screen Recording Permission (Selection Mode)

Selection Mode users have never needed Screen Recording permission. Requesting it when they enable Visual Context may cause friction:
- IT-managed machines may block the permission
- Users may be uncomfortable granting Screen Recording to a code tool
- Permission denial → feature silently doesn't work (confusing)

**Mitigation**: Clear first-run disclosure (Section 10.5). If permission denied, show a toast explaining why Visual Context won't work without it.

### 16.5 Vision Hallucination → Incorrect Explanation

If the vision model hallucinates code structure or file names that aren't visible, this fabricated "evidence" is injected into the explanation prompt. The explanation LLM may then reference non-existent functions, wrong class names, or phantom diagnostics.

**Mitigation**: The prompt says "ONLY what is visually present. Never infer or speculate." But this is a prompt-level control. Monitor for explanation errors correlated with Visual Context usage (track follow-up questions that ask "what X?" where X came from the evidence block).

### 16.6 Image Payload Size

Base64-encoded JPEG images are ~33% larger than binary. A 400KB JPEG becomes ~530KB base64. At scale, this increases network bandwidth and backend memory usage per request.

**Mitigation**: `maxVisionImageBytes` caps the image at 800KB. At alpha scale this is not a concern. For scale, consider a separate upload endpoint that accepts binary multipart instead of base64 in the JSON body.

---

## 17. Alternatives

### 17.1 Single Multimodal Stage

Send image + selected text to one multimodal model → explanation directly.

| | Two-Stage (Chosen) | Single-Stage |
|---|---|---|
| Latency | Higher (~2 sequential calls) | Lower (~1 call) |
| Cost | Higher (~2 inferences) | Lower (~1 inference) |
| Observability | High (can log extracted evidence) | Low (can't see what model used from image) |
| Debuggability | High (can isolate vision vs reasoning failures) | Low |
| Model dependency | Extraction model ≠ explanation model | Explanation model must support vision |
| Control | Can filter/validate evidence before explanation | No intermediate validation |

**Assessment**: Two-stage is correct for initial shipping. It provides the observability needed to validate whether the feature works, and the product validation analytics depend on being able to measure evidence quality independently. The latency cost is the tradeoff.

### 17.2 Accessibility API Context Extraction

Use macOS Accessibility API to read surrounding text from the editor — no screenshot, no vision model.

**Advantages**: Zero latency, zero cost, no privacy concern, no Screen Recording permission.
**Disadvantages**: Unreliable across editors (especially Electron-based like VS Code), no diagnostics detection, no file name extraction.

**Assessment**: Better long-term complement, not a replacement. Consider as a future enhancement: AX extraction for editors that support it (Xcode), vision fallback for editors that don't. Not viable as the sole approach today.

---

## 18. Complexity Audit

Items removed or simplified from the v1 design:

| v1 Design | Issue | Final Resolution |
|-----------|-------|------------------|
| 6-field `VisualContext` struct with XML parsing | Over-structured for ~100 tokens of output. XML tags waste token budget. `surroundingCode` invited code dumps. | `[VisualEvidence]` list with open `type` string. Line-based wire format. No XML. |
| `maxVisualContextCharacters = 3000` | Assumed large output. Unnecessary truncation logic. | Removed. 200-token hard cap makes character limits redundant. |
| Per-field truncation logic (truncate `surroundingCode` first, then `additionalContext`) | Complexity for a problem that doesn't exist with tight token budget. | Removed. Truncate at last complete line if > 200 tokens. |
| `VisualContext` struct with `isEmpty` checking 6 optional fields | Verbose nil-checking logic. | `items.isEmpty` — one check. |
| Separate `VisualContext` formatting method with if-let chains | Template logic for assembling 6 optional fields into a block. | `formatted()` method: `items.map { ... }.joined(separator: "\n")`. |
| `maxVisionResponseTokens = 1024` | Allowed the vision model to produce narrative-length output. | Reduced to 256 with 80-120 token target. |
| No prompt versioning | No way to compare quality across prompt iterations. | `vision_prompt_version` and `explanation_prompt_version` on every request log. |
| No utilization tracking | No way to know if evidence was actually used. | Per-item utilization measurement (Section 11.5). |

**Net result**: ~130 lines of v1 parsing/formatting/truncation logic eliminated. The `VisualContext` + `VisualEvidence` domain model is ~25 lines. Evidence injection is a 3-line conditional. Analytics are comprehensive enough to validate the feature's value.

---

## 19. Implementation Sequence

| Milestone | Scope | Verification |
|-----------|-------|-------------|
| VC-1 | `VisualContext` domain model + `AIProviderProtocol.generateVisionCompletion()` + backend `/api/gateway/vision` endpoint | Backend accepts image, returns text response. Client protocol compiles. |
| VC-2 | `VisualContextExtractor` + extraction prompt + `DecodeGatewayProvider` vision implementation | Extractor calls vision endpoint, returns `VisualContext?`. Unit tests with mock provider. |
| VC-3 | Selection Mode coordinator integration + toggle + first-run disclosure | Toggle enables VC. Coordinator captures screenshot, extracts evidence, injects into user message. Feature off by default. |
| VC-4 | Screenshot Mode coordinator integration (parallel OCR + vision) | Screenshot Mode extracts VC in parallel with OCR. |
| VC-5 | Analytics: vision request logging, toggle events, `visual_context` flag on explanation requests | Admin dashboard shows VC metrics. Quality comparison queries work. |

5 milestones, down from 8 in v1. Each milestone is independently verifiable.

---

## 20. Resolved Questions

| Question (from v1) | Resolution |
|---------------------|-----------|
| Capture region: full window vs cursor area? | Full focused window. More context is better given the evidence compression model — the vision model decides what's important, not the capture region. |
| Image resolution? | Resize to max 1536px wide, JPEG quality 0.75. |
| Vision model: same as explanation or separate? | Separate. Fast/cheap model for extraction (Haiku w/ vision). Configured via `AI_VISION_MODEL` env var, defaulting to explanation model. |
| Retry on failure? | No retry. Optional enrichment; failed attempt already cost latency. |
| Cache visual context? | No for v1. The working area may change between questions. |

---

## 21. Remaining Open Questions

1. **Evidence quality validation**: What is the minimum evidence quality threshold below which injection degrades explanations? This can only be answered empirically after implementation.

2. **Parallelization in Selection Mode**: `async let` for text capture + screenshot capture requires both to complete before proceeding. If text capture is fast (50ms) but screenshot capture is slow (500ms), the user waits an extra 450ms before the vision call even starts. Is this acceptable, or should vision extraction fire independently and race against the explanation?

3. **Multi-monitor**: If the user's editor is on display 1 but their mouse triggers the hotkey from display 2, `ScreenCaptureService` must capture the correct display. This may require capturing the focused window by PID rather than by mouse position.
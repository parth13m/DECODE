# CLAUDE.md — Decode

## Project Mission

Decode is a native macOS AI code explanation tool. Users highlight code in any editor, press a hotkey, and get an instant AI-powered explanation in a floating HUD. Decode provides AI access through a server-side gateway — users never configure API keys.

Stage: Pre-beta alpha, invite-only, 5–50 users.

---

## Current Project Status (June 2026)

Decode MVP is feature-complete and has passed stabilization. Current phase: **Alpha Launch Preparation**.

**Primary focus:**
- Internal dogfooding and alpha onboarding
- External alpha testing with real users
- Product reliability and user feedback collection

**Platform architecture:** User → Decode App → Decode Gateway → Claude. Users never provide API keys.

**Analytics & admin dashboard** — operational and production-validated:
- User management (edit, enable/disable, delete) and invite management
- Usage analytics, cost analytics, DSA vs General analytics
- Request logging, dashboard metrics, and explanation generation verified working
- Recent analytics debugging incident resolved by reverting to stable implementation

**Strategic priorities:**
- Learn from real users rather than adding major new features
- Avoid prompt redesigns, explanation-engine rewrites, analytics rewrites, or large architectural changes unless supported by real user evidence
- Reliability, maintainability, and user experience take priority over feature expansion

---

## Current Product State

Three modes, four hotkeys, all with follow-up questions and post-explanation code improvement:

| Mode | Trigger | Flow |
|------|---------|------|
| Selection | Double-tap Control | Capture selected text → AI → HUD |
| Screenshot | Double-tap Option | Drag-select region → OCR → AI → HUD |
| Session | `⌃⇧O` open file, then Double-tap Shift | Capture snippet → resolve session → build context → AI → HUD |

**Client**: Swift 6, macOS 15+, SwiftUI, Apple Development signed (Team `P5Y864DV5S`).
**Backend**: FastAPI + PostgreSQL + Alembic on Railway.
**Production AI**: `AI_ADAPTER=anthropic`, `AI_MODEL=claude-haiku-4-5-20251001`.
**Auth**: Invite-code activation → access token in Keychain → Bearer auth.

---

## Implemented Systems

Everything below is built, shipped, and working in production.

### Selection Mode
Double-tap Control → `AccessibilityCapture` (multi-strategy: AX focused element → AX text markers → AX tree walk → clipboard fallback for Chromium) → AI stream → HUD.

### Screenshot Mode
Double-tap Option → fullscreen NSPanel overlay → drag-to-select → ScreenCaptureKit → Vision OCR → AI stream → HUD.

### Session Mode
`⌃⇧O` opens any code file. Swift parsed via `SwiftSyntaxParser` (including `ExtensionDeclSyntax` — extension members are attached to their extended type), 9 other languages via `TreeSitterParser` + `GrammarRegistration` (Python, JS, TS, HTML, CSS, Java, C#, C, C++). File watching via `DispatchSource` with 300ms debounce. Sessions persisted to GRDB.

Double-tap Shift → capture snippet → `SessionResolver` auto-matches to best session → `ContextBuilderService` assembles snippet-anchored context (4-tier fallback) → `SnippetHealthClassifier` analyzes code health → AI stream → HUD.

### Session Resolution (`SessionResolver`)
Pinned session → unconditional override. Single session → trivial. Multiple sessions → scored by entity containment, file content match, recency. Low confidence → fallback to `activeSessionId`.

### Context Tiers (`ContextBuilderService`)
Token reduction of ~63–97% vs sending the full file.

| Tier | Condition | What's sent |
|------|-----------|-------------|
| tier1 | Snippet matches a parsed entity | Entity source + outline |
| tier2 | File ≤200 lines | Full file content |
| tier2.5 | Large file, snippet found by text search | ±30 surrounding lines + outline |
| tier3 | Large file, no match | Outline only |

`SessionContext.contextTier` computed property derives the tier string. Sent to backend via `context_tier` field on `ChatRequest`.

### Code Health (`SnippetHealthClassifier`)
Session Mode only. Tree-sitter parses the snippet. Edge errors (at snippet boundaries) are classified as partial-selection artifacts. Interior errors are real issues. Full-file validation cross-checks. Tiers: silent → observe → surface → diagnose, injected into the system prompt.

### Explanation Profiles
Two explanation profiles, toggled via DSA Mode switch in the main UI (`@AppStorage("dsaModeEnabled")`):

| Profile | Prompt Source | Focus |
|---------|--------------|-------|
| General (default) | V7 `adaptiveInstructions` in `ExplanationFramework.swift` | Software engineering understanding |
| DSA | `dsaInstructions` in `ExplanationFramework+DSA.swift` | Algorithms, complexity, patterns, interview prep |

Both profiles share `languageHint`, `tagVocabulary`, and `healthPromptAugmentation`. Profile selection happens in `styleInstructions(dsaMode:)`. Coordinators read `UserDefaults.standard.bool(forKey: "dsaModeEnabled")` at each hotkey event.

### Explanation Engine (V7)
Core prompt system in `ExplanationFramework.swift`. Assembled as: `languageHint` + `adaptiveInstructions` (V7 prompt) + `tagVocabulary`. 7 language families. Key principle: tell the developer what they cannot learn from reading the code.

### Tag Vocabulary
7 custom tags rendered by `ExplanationTagParser`: `<hl>`, `<critical>`, `<tip>`, `<note>`, `<analogy>` (inline); `<tldr>`, `<flow>` (block). Renderer uses `.inlineOnlyPreservingWhitespace` — block-level headings (`##`) are NOT supported.

### Follow-up Questions
`ExplanationHUDViewModel` stores `FollowUpContext` at stream time. `askFollowUp()` builds a 3-message conversation. Uses dedicated `followUpSystemPrompt`, NOT the explanation prompt.

### Improve Code
Post-explanation feature that generates AI-powered code improvements. Available in Selection and Session modes (not Screenshot — no original code to improve). Workflow: Explain Code → Improve Code → Review → Copy or Replace.

`ImprovementService` (stateless enum) builds the improvement prompt and parses responses. Uses `<improvement_summary>` and `<improved_code>` XML-like tags. `ImprovementSectionView` renders summary, original vs improved code comparison, and action buttons (Copy, Replace, Cancel). `TextReplacementService` handles replacement via clipboard backup → write → simulated ⌘V → clipboard restore.

The improvement prompt enforces a quality threshold: changes must meaningfully improve readability, maintainability, safety, performance, API design, naming clarity, simplicity, or code structure. Comment-only, formatting-only, and cosmetic-only changes are explicitly rejected. When no meaningful improvement exists, the model returns a summary-only response ("No meaningful improvement found.") with no `<improved_code>` tag. This is a successful outcome — the UI shows the summary with a Dismiss button, no code blocks or Copy/Replace actions.

Analytics: improvement requests use compound mode values (`selection_improve`, `session_improve`) via the existing `mode` field. No backend schema changes required.

Reliability protections: `improvementTask?.cancel()` guard prevents overlapping improvement requests. `isReplacing` reentrancy flag prevents concurrent Replace operations. Clipboard backup/restore prevents data loss. Frontmost app check prevents pasting into Decode itself.

### HUD Header
Displays mode + profile badge (`Selection · General`, `Session · DSA`, etc.) and, in Session Mode, the resolved session filename. Implemented in `FloatingExplanationHUD.headerView` via `ExplanationHUDViewModel.modeName`, `sessionFileName`, and `explanationProfile`.

### Request Concurrency
All three coordinators use a generation-counter pattern to prevent ghost requests. The `for await` loop dispatches handlers into a `Task` (non-blocking) and increments `requestGeneration` on each event. Previous handler tasks are cancelled. Handlers check `generation == requestGeneration` after each `await` — a mismatch means a newer request exists and the handler exits early. This ensures only the latest user request runs to completion.

### Session Dock
Non-activating `NSPanel` on right screen edge. Capsule pills with magnification. Pin session via context menu to override auto-resolution.

---

## Current Architecture

### Layered Architecture (strict downward dependency)

```
Presentation → Application → Domain → Infrastructure
```

Protocols for cross-layer communication (dependency inversion). No layer imports above it.

### Key Services by Layer

**App**: `AppDependencies` — root DI container, deferred startup, hotkey fan-out.
**Application**: `SelectionModeCoordinator`, `ScreenshotModeCoordinator`, `SessionQuestionCoordinator`, `SessionManager`, `SessionResolver`, `ContextBuilderService`, `ExplanationFramework`, `RepresentationGuidance`, `SnippetHealthClassifier`, `ImprovementService`.
**Domain**: Models (`Session`, `CodeEntity`, `SessionContext`, `AILimits`), Protocols (`AIProviderProtocol`, `DatabaseProtocol`).
**Infrastructure**: `DecodeGatewayProvider`, `AccessibilityCapture`, `HotkeyService`, `SwiftSyntaxParser`, `TreeSitterParser`, `DatabaseService`, `KeychainService`, `FileWatcherService`, `ScreenCaptureService`, `VisionOCRService`, `TextReplacementService`, `AnalyticsEventService`.
**Presentation**: `FloatingExplanationHUD`, `ExplanationHUDViewModel`, `ExplanationTagParser`, `ImprovementSectionView`, `FloatingSessionDock`, `SessionView`.

### Dependency Injection
`AppDependencies` (`@Observable @MainActor`) passed via `.environment()`. Manual DI — no framework.

### App Lifecycle
`AppDependencies.init()` performs only lightweight construction. All activation-sensitive work deferred to `performDeferredStartup()` via `didBecomeActiveNotification`. This prevents the "AppleEvent activation suspension timed out" race. Accessibility permission prompt is gated on `authService.state == .authenticated` — it fires only after the user has successfully activated their invite code, not on first launch before they understand what Decode does.

### Window Architecture
Main window (`WindowGroup`), Settings (`Settings` scene), HUD (`NSPanel`), Session sheet (`.sheet`), Session Dock (`NSPanel`).

### Codebase Structure
```
Decode/App/          → DecodeApp, AppDependencies, ContentView
Decode/Application/  → Coordinators, managers, context/explanation logic, ExplanationFramework+DSA
Decode/Domain/       → Models, Protocols, Services stubs
Decode/Infrastructure/ → AI/, AST/, Capture/, Database/, FileSystem/, Hotkey/, Keychain/, OCR/
Decode/Presentation/ → Overlay/, Session/, Onboarding/, Settings/
backend/app/         → routers/, models/, static/, gateway_service.py, auth.py, config.py, database.py
backend/alembic/     → Database migrations
```

---

## Explanation Engine

- Two profiles: General (V7) and DSA. Toggled via `dsaModeEnabled` UserDefaults key.
- V7 is the active general explanation prompt. V7 is currently frozen.
- DSA prompt lives in `ExplanationFramework+DSA.swift`. Independently evolvable.
- Do not redesign V7 without evidence from real-world usage.
- Future improvements should be driven by observed user behavior.
- Language detection: 7 families, file-extension + content heuristics.
- Follow-ups: 3-message conversation with dedicated `followUpSystemPrompt`. Stable.
- Profile selection: `ExplanationFramework.styleInstructions(dsaMode:)` selects the prompt. Shared infrastructure (language hints, tags, health augmentation) is profile-agnostic.

---

## Improve Code Feature

Post-explanation code improvement. After receiving an explanation, users can request an AI-generated improvement of the original code.

### Workflow

Explain Code → "Improve Code" button → AI generates improvement → Review original vs improved → Copy or Replace → Dismiss.

### Supported Modes

| Mode | Supported | Reason |
|------|-----------|--------|
| Selection | Yes | Original code available via `FollowUpContext.originalCode` |
| Session | Yes | Original snippet available via `FollowUpContext.originalCode` |
| Screenshot | No | OCR text is not replaceable source code |

### Architecture

| Component | Layer | Responsibility |
|-----------|-------|----------------|
| `ImprovementService` | Application | Prompt construction, response parsing, mode builder |
| `TextReplacementService` | Infrastructure | Clipboard + ⌘V replacement, frontmost app guard |
| `ImprovementSectionView` | Presentation | Summary card, code comparison, action buttons |
| `ExplanationHUDViewModel` | Presentation | Improvement state management, task lifecycle |

Response format uses `<improvement_summary>` and `<improved_code>` XML-like tags, parsed by `ImprovementService.parseResponse()`.

### Prompt Philosophy

Improvements must meaningfully improve at least one of:
- Readability, maintainability, safety, performance
- API design, naming clarity, simplicity, code structure

Explicitly rejected as non-improvements:
- Comment-only changes
- Formatting-only or whitespace-only changes
- Cosmetic renames to synonyms of equal clarity
- Type annotations the compiler already infers

### No-Improvement Path

When no meaningful improvement exists, the model returns summary-only:

```
<improvement_summary>
No meaningful improvement found.

The current implementation is already clear and appropriate for its purpose.
</improvement_summary>
```

This is a successful outcome. The UI shows the summary card with a Dismiss button. No code blocks, no Copy/Replace buttons. Do not force code modifications when the original is already appropriate.

### Reliability Protections

- **Improvement task guard**: `improvementTask?.cancel()` at the start of `requestImprovement()` prevents overlapping improvement tasks.
- **Replacement reentrancy**: `isReplacing` flag set synchronously before the async replacement task. `canReplace` checks this flag. Prevents concurrent Replace operations.
- **Clipboard safety**: `backupPasteboard` → modify → paste → `restorePasteboard`. Original clipboard contents preserved.
- **Frontmost app guard**: `TextReplacementService` checks `NSWorkspace.shared.frontmostApplication` to prevent pasting into Decode itself.

### Known Limitation

Replace uses `CGEvent.post(tap: .cghidEventTap)` to simulate ⌘V. After clicking the Replace button, the HUD panel may become the key window, causing the paste event to target the panel instead of the editor. This is a known issue under investigation. The frontmost app check does not catch this because `.nonactivatingPanel` keeps the editor as the active application while the HUD holds key window status.

---

## Context-Aware Session Improve

Session Improve reuses the `SessionContext` from the original explanation. `FollowUpContext.sessionContext` stores the same `SessionContext` instance that was built during the explanation flow. No separate context-selection system exists. No prompt parsing, no context recomputation, no file re-reads.

- `ImprovementService.contextAwareSystemPrompt(context:)` builds a Session Improve prompt from the stored `SessionContext`.
- The improvement prompt includes the same tier-selected data (entity source, full file, surrounding code, or outline) but with improvement-specific instructions — no explanation formatting, no representation guidance, no health augmentation.
- `contextTier` is now passed for session improvement requests (was `nil` before).
- Selection Improve remains context-light — uses the generic `ImprovementService.systemPrompt` with only the selected code.

---

## Improve Code Analytics

Improve Code has two analytics layers:

**Request analytics** — tracked in `request_logs` via compound mode values (`selection_improve`, `session_improve`). These participate in all standard analytics: token counts, latency, cost, profile breakdowns. Improvement requests preserve `explanation_profile` and `language` from the original explanation.

**Product analytics** — tracked in `analytics_events` table via `AnalyticsEventService`. Four event types:

| Event | When fired |
|-------|-----------|
| `improve_copy` | User copies improved code to clipboard |
| `improve_replace` | User replaces editor selection (includes `replace_result` metadata) |
| `improve_dismiss` | User dismisses improvement after viewing |
| `improve_no_change` | AI found no meaningful improvement to suggest |

LOC metadata collected on copy/replace events: `original_loc`, `improved_loc`, `loc_delta`.

Dashboard sections: global Improve Code stats (adoption rate, acceptance rate, no-change rate, replace failure rate) and per-user improve breakdown.

---

## Follow-Up Analytics

Follow-up questions use compound mode values in `request_logs`:

| Mode | Original |
|------|----------|
| `selection_followup` | `selection` |
| `session_followup` | `session` |
| `screenshot_followup` | `screenshot` |

Follow-ups preserve `explanation_profile` and `language` from the original explanation via the 6-param `streamChat` overload.

Dashboard analytics: Total Follow-Ups, Follow-Up Rate, Avg Input/Output/Total Tokens, Total Follow-Up Cost. Per-user breakdown with the same metrics. Follow-up modes appear automatically in the Mode Analytics table (GROUP BY `mode`).

Follow-ups participate in profile-scoped analytics (Combined / General / DSA) via the standard `?profile=` query parameter.

---

## Analytics Philosophy

- **Request analytics** measure API usage: tokens, latency, cost, success rate. Stored in `request_logs`.
- **Product analytics** measure user behavior: copy, replace, dismiss, no-change. Stored in `analytics_events`.
- These are separate concerns. Do not conflate them.
- Reuse existing context and analytics infrastructure. Do not create duplicate systems.
- Prefer compound mode values (`selection_improve`, `session_followup`) over new columns or tables.
- Prefer incremental instrumentation over large telemetry frameworks.
- `AnalyticsEventService` is fire-and-forget — analytics failures must never block UX.

---

## V7 Design Principles

- Explain like an experienced engineer.
- Prioritize understanding over description.
- Use adaptive structure — choose the smallest structure that fully explains the code.
- Do not force sections.
- Visuals should emerge from the code, not be imposed.
- Avoid obvious observations and unnecessary narration.

---

## Visual Vocabulary

Current explanation components: Quick Explanation, Key Insight, Workflow, Table, Hierarchy, Branching Flowchart, Risks / Edge Cases, Summary.

Branching Flowchart should only be used when:
- 3+ exit paths.
- Branching is the primary purpose.
- Minimal post-branch processing.

---

## Renderer Architecture

- Extend the existing renderer architecture incrementally.
- Do not introduce a semantic PresentationNode architecture unless future evidence justifies it.
- Prefer low-risk evolution over large rewrites.

---

## Renderer Status

Phase 1 is complete. Supported: Workflow, Hierarchy, Branching Flowchart, Code Blocks, Tables. Backward compatibility with legacy AEE tags is preserved.

---

## Tag Vocabulary

- Tag vocabulary remains enabled. Moderate-compression version is active.
- 7 tags: `<hl>`, `<critical>`, `<tip>`, `<note>`, `<flow>`, `<tldr>`, `<analogy>` (reserved).
- Renderer uses `.inlineOnlyPreservingWhitespace` — block-level headings (`##`) are NOT supported.
- Do not remove tags without auditing: Code Health, renderer consumers, follow-up prompts.

---

## Analytics System State

Full analytics pipeline, shipped and verified in production.

### What's Tracked (per request in `request_logs`)
`user_id`, `mode`, `success`, `latency_ms`, `error_type`, `ai_provider`, `ai_model`, `context_tier`, `explanation_profile`, `prompt_tokens`, `completion_tokens`, `total_tokens`, `prompt_character_count`, `language`, `created_at`.

### Product Events (in `analytics_events`)
`user_id`, `event_type`, `mode`, `metadata` (JSONB), `created_at`. See Improve Code Analytics section.

### Token Extraction
All 3 gateway adapters extract provider-reported token usage with normalized keys. `prompt_character_count` computed server-side from message + system prompt length.

### Context Tier Tracking
Client derives tier from `SessionContext.contextTier`, sends as `context_tier` string in `ChatRequest`. Sent for `session` and `session_improve` modes. Selection/Screenshot modes send `nil` (no context tier).

### Explanation Profile Tracking
Client sends `explanation_profile` (`"general"` or `"dsa"`) as a separate field on `ChatRequest`, orthogonal to `mode`. All three modes send the profile. Historical rows have `NULL` (pre-DSA).

### Cost Estimation
Server-side `_MODEL_PRICING_PER_MTOK` lookup in `admin.py`. Currently covers `claude-haiku-4-5-20251001` and `llama-3.3-70b-versatile`. Returns `None` for unknown models. Update the dict when models or pricing change.

### Legacy Rows
Pre-analytics rows have NULL for all analytics columns. Queries filter with `IS NOT NULL`. `analytics_coverage` metric tracks what % of rows have data.

---

## Platform Architecture

### Multi-Provider Gateway (`gateway_service.py`)
Three adapter families selected by `AI_ADAPTER` env var:
- `openai_compat` — Groq, OpenAI, OpenRouter, Together, Fireworks, DeepSeek, custom.
- `anthropic` — Anthropic Messages API.
- `gemini` — Google Gemini.

`call_llm()` returns `(content, latency_ms, token_usage)`. 120s timeout. Provider-agnostic.

Known provider shortcuts: setting `AI_ADAPTER=groq` auto-resolves to `openai_compat` with Groq's URL.

### Authentication Flow
1. Admin generates invite code via `POST /api/admin/invite` → `DECODE-XXXX-XXXX`.
2. User activates via `POST /api/auth/activate` → receives access token.
3. Token stored as SHA-256 hash server-side, raw token in Keychain client-side.
4. All gateway requests use Bearer auth.

### Client-Side Limits
`AIUsageTracker`: 100 requests per 5-hour rolling window (UserDefaults).
`AILimits`: maxResponseTokens (4096), maxFileSizeBytes (512 KB), maxSelectedTextCharacters (15,000), maxOCRTextCharacters (10,000).

### Database
**Backend (PostgreSQL)**: `users` (id, email, status, invite_code, token_hash, timestamps), `request_logs` (16 columns — see Analytics section), `analytics_events` (product analytics — see Improve Code Analytics section).
**Client (GRDB/SQLite)**: `sessions` + `entities`, WAL mode, `DatabasePool`.

---

## Admin Dashboard State

Served at `GET /admin`. Single-page HTML/JS. Token-based auth via `ADMIN_TOKEN` env var.

### Current Sections
1. **Analytics** — stat cards: users by status, requests by mode/success, success rate, avg/p50/p95 latency, analytics coverage, estimated total cost.
2. **Token Analytics** — 3 cards: avg prompt/completion/total tokens.
3. **Improve Code** — adoption rate, acceptance rate, copy/replace/dismiss/no-change counts, replace failure rate (hidden when no data).
4. **Follow-Up Questions** — total follow-ups, follow-up rate, avg input/output/total tokens, total follow-up cost (hidden when no data).
5. **Mode Analytics** — per-mode table: mode, requests, success %, avg latency, avg tokens, estimated cost. Automatically shows all compound modes.
6. **Tier Performance** — 10-column table: tier, requests, % of total, success %, avg latency, avg prompt/completion/total tokens, avg prompt chars, estimated cost.
7. **Provider Analytics** — 8-column table: provider, model, requests, success %, failures, avg latency, avg total tokens, estimated cost.
8. **Explanation Profile** — 5-column table (hidden when no data): profile, requests, success %, avg latency, avg total tokens.
9. **Error Breakdown** — 2-column table (hidden when no errors): error type, count.
10. **Generate Invite** — email + invite code generation.
11. **Users** — per-user table with detail view including mode, improve, follow-up, tier, token, and cost breakdowns.

### Endpoints
`GET /api/admin/analytics`, `GET /api/admin/users`, `POST /api/admin/invite`, `POST /api/admin/users/{id}/disable`, `POST /api/admin/users/{id}/enable`.

---

## Alpha Strategy

- **Invite-only access**: Admin generates codes, users activate.
- **Server-side AI**: Users never configure API keys.
- **Quota-limited**: 100 requests per 5-hour rolling window.
- **Monitoring**: Admin dashboard tracks per-user usage, per-tier performance, provider reliability, error patterns, estimated cost.
- **Model switchable**: Change `AI_ADAPTER` + `AI_MODEL` env vars. No client update required.

---

## Finalized Architectural Decisions

These are closed decisions. Do not re-investigate or propose alternatives.

1. **ARE v2 (representation steering)**: Prompt-based representation steering has ~80% ignore rate with current models. Root cause is model instruction-following, not architecture. Deferred until model upgrade or user demand.
2. **Context tier system**: 4 tiers (tier1→tier3) with ContextBuilderService. Design is stable. Tier2.5 (±30 surrounding lines) added as local context fallback for large files.
3. **Code health classification**: Edge vs interior error classification with full-file validation. Thresholds are tuned. System is stable.
4. **Manual DI**: `AppDependencies` as root container. No DI framework. This is intentional.
5. **Deferred startup**: All activation-sensitive work in `performDeferredStartup()`. Required to avoid macOS activation timeout race.
6. **Analytics pipeline**: Server-side token extraction with normalized keys. Client sends `context_tier` and `explanation_profile`. All analytics columns nullable for backward compatibility.
7. **Cost estimation**: Approximate, based on `_MODEL_PRICING_PER_MTOK` dict. Acceptable for alpha. Not a billing system.
8. **No SSE streaming**: Gateway returns complete response. Client simulates streaming from the single chunk. SSE is deferred.
9. **Sandbox disabled**: Re-enabling requires security-scoped bookmarks. Not a priority for alpha.
10. **Request replacement via generation counter**: Coordinators use `requestGeneration` + `activeRequestTask?.cancel()` to ensure only the latest request runs. No mutex, no queue — MainActor isolation + generation checks after each `await` are sufficient.
11. **DSA Mode as separate prompt (Approach A)**: DSA uses a fully separate prompt (`dsaInstructions`) rather than an overlay on V7 or a profile abstraction. Keeps V7 isolated. DSA prompt lives in `ExplanationFramework+DSA.swift`. `explanation_profile` is tracked as a separate analytics dimension from `mode` (not encoded in mode strings). If a third profile emerges, refactor to a profile enum.

---

## Explicitly Deferred Features

Do not build these unless explicitly requested.

| Feature | Reason |
|---------|--------|
| AI quality ratings (thumbs up/down) | No user feedback mechanism yet. Wait for alpha feedback. |
| User-configurable hotkeys | Current hotkeys work. Complexity not justified for alpha. |
| Cross-file context / dependency graph | Major effort. Wait for user demand. |
| AI entity summaries | Speculative. No validated need. |
| Onboarding funnel | Not needed at 5–50 invite-only users. |
| SSE streaming | Current single-chunk approach works. Latency improvement is marginal. |
| ARE artifact generation | Investigated, deferred. Model capability is the bottleneck. |
| Time-windowed analytics | Not useful until daily request volume exceeds ~50. |
| Per-user token consumption tracking | Not needed at current user count. |

---

## Current Priorities

1. Real-world explanation quality validation — validate V7 and DSA prompt against real developer workflows. Do not create V8 or redesign the explanation system until sufficient evidence is collected from actual usage.
2. DSA Mode validation — monitor DSA usage via `explanation_profile` analytics. Iterate DSA prompt based on real feedback. Do not add new profiles until DSA is validated.
3. Alpha user testing (5–50 users) — monitor real usage patterns.
4. Gateway reliability — track error rates, latency, provider health via admin dashboard.
5. Context optimization validation — use tier analytics to measure token reduction effectiveness.

---

## Development Workflow

### Build and Run
```bash
xcodegen generate                    # After project.yml changes or new files added
open Decode.xcodeproj                # Scheme: Decode → My Mac → Cmd+R
```

**Command-line build:**
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Decode.xcodeproj -scheme Decode -configuration Debug build
```

**Config**: Swift 6.0, `SWIFT_STRICT_CONCURRENCY = complete`, macOS 15.0, Xcode 16.2, sandbox disabled.
**Dependencies**: GRDB 7.5.0, SwiftSyntax 600.0.1, SwiftTreeSitter + 9 language grammars.
**First launch**: Requires Accessibility, Input Monitoring, Screen Recording permissions + restart.

### Git
Main branch: `main`. Build must pass before committing. Run `xcodegen generate` after adding/removing Swift files.

### Tests
13 test files exist in `DecodeTests/`. Coverage is still thin — priority candidates for expansion: `ContextBuilderService`, `SessionResolver`, `SnippetHealthClassifier`, `ExplanationTagParser`.

---

## Development Principles

1. **Information density over narration.** Explanations should tell users what they can't see by reading the code.
2. **Server-side intelligence.** Analytics, token tracking, cost estimation — all server-side. Client stays thin.
3. **Backward compatibility by default.** New DB columns are nullable. New API fields have defaults. Old clients don't break.
4. **Measure before optimizing.** Analytics pipeline exists to validate assumptions. Don't optimize based on intuition.
5. **Incremental shipping.** Small, verifiable changes deployed frequently. No multi-week branches.

---

## Common Mistakes to Avoid

### macOS-Specific
- **Never do startup work in `init()` or SwiftUI body.** Defer to `performDeferredStartup()`. Causes activation timeout.
- **Never use `NSApp.activate()` in overlays.** Causes Space-switching. Use `orderFrontRegardless()`.
- **Accessibility permissions bind to CDHash.** Ad-hoc signing breaks on rebuild. Use Apple Development signing.
- **macOS 15 Input Monitoring is separate from Accessibility.** `AXIsProcessTrusted()` doesn't cover global event monitors. Both permissions required. UI detects Input Monitoring independently via `CGPreflightListenEventAccess()`.
- **NSEvent global monitors fail silently.** Return non-nil even without permission.
- **Chromium apps need clipboard fallback.** AX returns nothing for selected text.
- **Stale sandbox container** at `~/Library/Containers/com.decode.app/` intercepts UserDefaults even with sandbox disabled.

### Decode-Specific
- **Never use markdown headings (`##`) in LLM prompts.** Tag renderer uses `.inlineOnlyPreservingWhitespace`. Use `**bold**`.
- **Never infer active session.** Use `activeSessionId` set by explicit user action only.
- **Never watch the file directly.** Watch parent directory to survive atomic saves.
- **Never reuse the explanation system prompt for follow-ups.** Follow-ups use `followUpSystemPrompt`.
- **Never forget `rebuildAIProvider()` after auth state changes.** Missing this leaves `aiProvider` nil.
- **All `print()` must be `#if DEBUG` gated.** No print output in release builds.
- **Run `xcodegen generate` after adding or removing Swift files.**
- **Update `_MODEL_PRICING_PER_MTOK` in admin.py** when switching AI models. Cost estimation returns None for unknown models.
- **`_log_request()` uses a separate `SessionLocal()`** for transaction isolation. Failures are logged with `DECODE_REQUEST_LOG_FAILURE_V1`.
- **Never `await` the handler inside a coordinator's `for await` loop.** Use `Task { await handler() }` with generation counter. Awaiting directly blocks the loop and causes ghost requests to queue.
- **Never encode explanation profile into mode strings.** `mode` and `explanation_profile` are orthogonal analytics dimensions. Mode = how text was captured. Profile = how it's explained. They are separate fields on `ChatRequest` and `request_logs`.
- **Never force improvement output when code is already clean.** The improvement prompt explicitly supports a no-improvement path. Comment-only, formatting-only, and cosmetic changes do not qualify as improvements.

---

## Technical Debt

1. **Test coverage thin** — 13 test files exist but key services lack coverage.
2. **Sandbox disabled** — re-enabling requires security-scoped bookmarks.
3. **No `os.Logger` in release builds** — only server-side observability exists.
4. **Entity sync not transactional** — no DB transaction wrapper.
5. **SQL grammar excluded** from tree-sitter — upstream SPM package issue.
6. **No server-side request cancellation** — when client cancels a request (new hotkey press), the client-side URLSession task is torn down but the server-side httpx→Anthropic call runs to completion. Requires FastAPI disconnect detection + asyncio task cancellation. Medium complexity.

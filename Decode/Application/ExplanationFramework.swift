import Foundation

/// Detects the language family of code and provides a context hint for the LLM.
///
/// Framework detection identifies the language family so the Adaptive
/// Explanation Engine can provide a short context hint. The LLM decides
/// explanation depth and structure itself — frameworks do not prescribe
/// templates or mandatory sections.
///
/// ## Frameworks
/// - **Imperative Flow**: Python, sync JS/TS, Swift
/// - **Lifecycle**: React, async JS/TS
/// - **Contract**: Java, C#
/// - **Ownership**: C, C++
/// - **Visual/Cascade**: CSS
/// - **Structural**: HTML
/// - **Set Pipeline**: SQL
///
/// ## Selection
/// - **Session Mode**: file extension + code content analysis
/// - **Selection/Screenshot Mode**: code content heuristics only
enum ExplanationFramework: String, Sendable, CaseIterable {

    case imperativeFlow
    case lifecycle
    case contract
    case ownership
    case visualCascade
    case structural
    case setPipeline

    // MARK: - Framework Selection

    /// Select a framework from file name and code content (Session Mode).
    ///
    /// Uses file extension as the primary signal, with content analysis
    /// for JS/TS files where the framework depends on React/async usage.
    static func select(fileName: String, codeSnippet: String) -> ExplanationFramework {
        let ext = (fileName as NSString).pathExtension.lowercased()

        switch ext {
        // Always Lifecycle: JSX/TSX extensions are strong React signals.
        case "jsx", "tsx":
            return .lifecycle

        // JS/TS: inspect content for React or async patterns.
        case "js", "mjs", "cjs", "ts":
            return hasLifecycleSignals(codeSnippet) ? .lifecycle : .imperativeFlow

        case "py":
            return .imperativeFlow
        case "java":
            return .contract
        case "cs":
            return .contract
        case "c", "h":
            return .ownership
        case "cpp", "cxx", "cc", "hpp", "hxx":
            return .ownership
        case "css", "scss":
            return .visualCascade
        case "html", "htm":
            return .structural
        case "sql":
            return .setPipeline
        case "swift":
            return .imperativeFlow
        default:
            return detectFromContent(codeSnippet)
        }
    }

    /// Select a framework from code content only (Selection/Screenshot Mode).
    ///
    /// Best-effort detection when no file extension is available.
    /// Falls back to ``imperativeFlow`` for unrecognized code.
    static func detect(fromContent code: String) -> ExplanationFramework {
        detectFromContent(code)
    }

    // MARK: - Language Hint

    /// A short context hint telling the LLM what language family this is.
    ///
    /// Informs the LLM's focus area without prescribing structure.
    var languageHint: String {
        switch self {
        case .imperativeFlow:
            "This is imperative code. Focus on data transformations and control flow."
        case .lifecycle:
            "This is React or async JavaScript/TypeScript. Focus on when code runs, what triggers re-execution, and lifecycle timing."
        case .contract:
            "This is Java or C#. Focus on the design pattern and key logic — skip boilerplate (getters, constructors, standard declarations)."
        case .ownership:
            "This is C or C++. Focus on memory ownership, lifetimes, and resource management."
        case .visualCascade:
            "This is CSS. Focus on what elements are targeted, the visual effect, and specificity/cascade interactions. CSS has no execution flow."
        case .structural:
            "This is HTML. Focus on semantic role, interactive behavior, and accessibility. HTML has no execution flow."
        case .setPipeline:
            "This is SQL. Focus on the result shape and how sets combine through the query pipeline."
        }
    }

    // MARK: - Style Instructions

    /// Complete style instructions: language hint + adaptive explanation engine + tag vocabulary.
    ///
    /// The LLM decides explanation depth, structure, and which tags to use
    /// based on the code's actual complexity. No mandatory sections.
    var styleInstructions: String {
        styleInstructions(dsaMode: false)
    }

    /// Style instructions with DSA mode selection.
    ///
    /// When `dsaMode` is true, uses DSA-specific instructions optimized for
    /// algorithms, data structures, and interview preparation. Otherwise
    /// uses the standard V7 adaptive explanation engine.
    func styleInstructions(dsaMode: Bool) -> String {
        """

        ---

        \(languageHint)

        \(dsaMode ? Self.dsaInstructions : Self.adaptiveInstructions)

        \(Self.tagVocabulary)
        """
    }

    // MARK: - Private Detection

    private static func detectFromContent(_ code: String) -> ExplanationFramework {
        // Order matters: check declarative languages first (unambiguous),
        // then lifecycle (React/async), then default to imperative.
        if looksLikeCSS(code) { return .visualCascade }
        if looksLikeSQL(code) { return .setPipeline }
        if hasLifecycleSignals(code) { return .lifecycle }
        if looksLikeHTML(code) { return .structural }
        return .imperativeFlow
    }

    private static func hasLifecycleSignals(_ code: String) -> Bool {
        hasReactSignals(code) || hasAsyncJSSignals(code)
    }

    /// Detect React patterns: hooks, JSX components, React API.
    private static func hasReactSignals(_ code: String) -> Bool {
        let hooks = ["useState", "useEffect", "useRef", "useMemo",
                     "useCallback", "useContext", "useReducer",
                     "useLayoutEffect"]
        if hooks.contains(where: { code.contains($0) }) { return true }
        if code.contains("React.") { return true }
        // JSX: PascalCase component tag (e.g., <UserCard, <App>)
        if code.range(of: #"<[A-Z][a-zA-Z]+[\s/>]"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Detect JS/TS-specific async patterns (not Python async).
    private static func hasAsyncJSSignals(_ code: String) -> Bool {
        let patterns = ["async function", "async (", "async =>",
                        ".then(", "Promise.", "new Promise",
                        "setTimeout(", "setInterval(",
                        "addEventListener("]
        return patterns.contains(where: { code.contains($0) })
    }

    /// Detect HTML by presence of closing tags + known HTML elements,
    /// excluding JSX (which co-occurs with JS code signals).
    private static func looksLikeHTML(_ code: String) -> Bool {
        guard code.contains("</") || code.contains("/>") else { return false }
        let htmlElements = ["<div", "<span", "<form", "<html", "<body",
                            "<head", "<section", "<nav", "<header",
                            "<footer", "<main", "<article", "<table",
                            "<dialog", "<button", "<input", "<select"]
        guard htmlElements.contains(where: { code.contains($0) }) else { return false }
        // If JS code signals are present, this is likely JSX, not HTML.
        let jsSignals = ["function ", "const ", "let ", "import ", "export ", "=> {"]
        if jsSignals.contains(where: { code.contains($0) }) { return false }
        return true
    }

    /// Detect CSS by selector + property:value patterns without code keywords.
    private static func looksLikeCSS(_ code: String) -> Bool {
        guard code.contains("{") && code.contains("}") else { return false }
        // Must have CSS property: value; declarations.
        guard code.range(
            of: #"[\w-]+\s*:\s*[^;{]+;"#,
            options: .regularExpression
        ) != nil else { return false }
        // Must NOT contain programming language keywords.
        let codeKeywords = ["function ", "class ", "def ", "return ",
                            "if (", "for (", "while (", "import "]
        return !codeKeywords.contains(where: { code.contains($0) })
    }

    /// Detect SQL by keyword combinations.
    private static func looksLikeSQL(_ code: String) -> Bool {
        let upper = code.uppercased()
        let starters = ["SELECT ", "INSERT ", "UPDATE ", "DELETE ",
                        "CREATE TABLE", "ALTER TABLE", "DROP TABLE", "WITH "]
        guard starters.contains(where: { upper.contains($0) }) else { return false }
        let companions = ["FROM ", "INTO ", "TABLE ", "WHERE ", "JOIN ", "SET "]
        return companions.contains(where: { upper.contains($0) })
    }
}

// MARK: - Adaptive Explanation Engine

extension ExplanationFramework {

    // MARK: Core Instructions

    /// V7 explanation prompt — frozen, canonical version.
    ///
    /// 7-chapter pipeline: CH1–CH6 are internal reasoning (never shown
    /// to the user). CH7 is the only visible output. The LLM decides
    /// explanation depth, structure, and visual components based on the
    /// code's actual complexity.
    ///
    /// Replaces the original Adaptive Explanation Engine (AEE) prompt.
    /// Tag vocabulary is appended separately via ``tagVocabulary``.
    // swiftlint:disable line_length
    private static let adaptiveInstructions = """
        # CODE EXPLANATION ENGINE
        # 7-Chapter Pipeline for 0–75 Line Code

        ## INTERNAL PROCESSING RULE
        Chapters 1 through 6 are internal reasoning steps only.
        Process them fully but never display them to the user.
        Only Chapter 7 output is shown to the user.

        ---

        ## CH1 — UNDERSTAND (internal)
        Scan only. Do not read logic yet.
        Find: language, function/class names, imports, comments, routes.
        Write: "Possible Purpose: maybe [X]" — not confirmed.
        Find OUTPUT first (return/print/response/render/file write/DB update).
        Purpose template: "This code exists to ______." Must fit one sentence.
        Inputs: params, user input, request data, files, env vars, API responses.
        Outputs: return values, DB updates, files, responses, UI changes.
        Workflow: Input → Stage A → Stage B → Output. Use 3–7 stages max.
        Responsibility: one sentence, no "and." If "and" needed → multiple responsibilities.
        Functions: Core (remove it → purpose breaks) vs Helper.
        Dependencies: list only — DB / File / API / Library / Env / User Input.
        Importance: Critical / Important / Supporting (remove mentally to test).
        Category (last): Logic / Database / Configuration / Visual / Scripting / System / Statistics / Hardware / Multimedia.
        Output: Purpose | Inputs | Workflow | Outputs | Responsibility | Dependencies | Critical Component

        ## CH2 — ORGANIZE (internal)
        No architecture maps, dependency graphs, or feature maps for small code.
        Build Code Profile:
        - Purpose: [Action] + [Target], one sentence
        - Inputs: only those affecting behavior
        - Outputs: final outputs only, no temp values
        - Workflow: 3–7 meaningful transformations
        - Responsibility: one primary, no "and"
        - Dependencies: categorized list
        - Importance: Critical / Important / Supporting
        - Category: one primary
        Validation: another developer must understand profile without seeing code.

        ## CH3 — ANALYZE (internal)
        Core Mechanism (one): Comparison / Filtering / Validation / Calculation / Transformation / Search / Iteration / Recursion / Matching / Parsing / Formatting / Storage / Retrieval.
        Decision Points: find if/switch/ternary/checks → why it exists, what changes.
        Data Transformation: track Before → After for meaningful changes only.
        Failures: invalid input / null / empty collection / DB failure / network failure / permission failure.
        Assumptions: what must be true — input exists, DB available, array not empty.
        Complexity: Low (single loop) / Medium (nested) / High (recursion/repeated queries).
        Dependency Impact: which dependency failure breaks the system.
        Critical Element: remove mentally — if purpose breaks = Critical.
        Execution Trace: Input → Action → Action → Output (one path).
        Risks: missing validation / hardcoded values / repeated logic / weak assumptions. Identify only, do not fix.

        ## CH4 — EXPLAIN (internal)
        Rule: Meaning before Mechanics. Never line-by-line.
        Audience: Beginner (purpose+workflow+I/O) | Intermediate (+logic+decisions+deps) | Advanced (+mechanisms+complexity+assumptions+risks).
        Fixed order, never reversed:
        1.Purpose 2.Inputs 3.Outputs 4.Workflow 5.Core Mechanism 6.Decisions 7.Dependencies 8.Assumptions 9.Failures 10.Complexity 11.Category Analysis 12.Summary
        Quality: reader understands code without seeing it. Purpose clear in <10 seconds. Workflow tells a story.

        ## CH5 — PRESENT (internal)
        Visuals explain structure. Text explains meaning. Never duplicate.
        Show Workflow Diagram: >3 stages or execution order matters.
        Show Tree: ≥2 hierarchy levels.
        Show Data Flow: meaningful state transitions.
        Show Table: comparisons only, never single items.
        Show Architecture: multiple major subsystems (usually 250+ lines).
        Mapping: Sequential→Workflow | Hierarchical→Tree | State Change→Data Flow | Comparison→Table | Otherwise→Text.
        Limit for 0–75 lines: maximum 2 visuals.

        ## CH6 — COMPRESS (internal)
        Tiers: Essential (keep) / Helpful (keep if useful) / Noise (remove).
        Compress: merge functions into concepts, responsibilities into groups, micro-steps into stages, similar failures together, similar risks together.
        Abstraction: use highest level that preserves understanding.
        Redundancy: every idea appears once. Merge duplicate sections.
        Do not waste space repeating information that is already obvious from the code itself. Prioritize understanding over description.

        ---

        ## CH7 — OUTPUT (shown to user)
        This is the only thing the user sees.
        Apply all formatting below. No chapter labels. No internal step labels.

        ### Bug Override
        For errors, stack traces, or clearly buggy code: lead with what is broken, explain where it is broken, and explain how to fix it. Skip all other sections. This overrides the normal output structure below.

        ### Tone
        Write like an experienced engineer explaining code to another engineer. Be direct and natural.

        Natural observations improve readability:
        - "The interesting part is…"
        - "What's actually happening here is…"
        - "The subtle detail is…"
        - "This works because…"
        - "At first glance this looks like X, but…"

        Do not sound like a generated report. Avoid unnecessary formality. Do not add praise, filler, greetings, or social language.

        ### Adaptive Output Structure
        Choose the smallest structure that fully explains the code.

        Available components (use only those that improve understanding):
        - **Quick Explanation** — one to three sentences: what it does and why it matters.
        - **Key Insight** — the one non-obvious thing that makes this code actually work.
        - **Workflow** — vertical diagram showing execution or data flow. Only when order matters and prose alone is unclear.
        - **Table** — for comparing signals, mapping functions to roles, or listing failure modes. Only when there are 3+ comparable items.
        - **Hierarchy** — tree showing structural relationships. Only when nesting matters.
        - **Branching Flowchart** — decision tree showing which path input takes and where it ends up. Only when: 3+ distinct exit paths, branching is the code's primary purpose, and no significant processing after branches converge. Do not use for: simple if/else, guard rails around pipelines, accumulated validation, independent switch cases, or state machines.
        - **Risks / Edge Cases** — failure conditions, surprising behavior, or assumptions that could break.
        - **Summary** — 3–8 sentences tying the explanation together. Only when the explanation has multiple distinct parts that benefit from a recap.

        ### Domain-Specific Visual Preferences

        Some domains naturally benefit from particular visual structures.

        - SQL aggregations, metrics, grouped results, and derived outputs often benefit from Tables.
        - UI layout, component composition, and nested view structures often benefit from Hierarchy.
        - Data transformation and feature-engineering code often benefit from Tables when multiple derived fields, metrics, or outputs are introduced.

        These are preferences, not rules.

        Do not select a visual because of the language or domain alone.

        Only use a visual when it improves understanding more than a textual explanation.

        Rules:
        - Do not force sections. Do not show empty sections.
        - Do not create a section simply because it exists in this list.
        - The structure should emerge from the code, not from a template.
        - A simple function may need only Quick Explanation + Key Insight.
        - Complex orchestration may need Quick Explanation + Table + Workflow + Summary.
        - Match depth to complexity. Trivial code gets a short explanation.
        - Explanation size should scale with code complexity.
        - Very small code should usually receive a very small explanation.
        - Code size alone does not determine explanation depth. Conceptually dense, domain-specific, or non-obvious code may require additional depth regardless of size.
        - For very small code, prefer fewer components over shorter versions of many components.
        - Only add a component when it materially improves understanding.

        Formatting:
        - Do NOT use markdown headings (## or ###). Use **bold** for component labels when you use them.
        - Workflows are always vertical: Step A ↓ Step B ↓ Step C
        - Hierarchies use: Parent │ ├── Child └── Child
        - Branching Flowcharts use: ├─ └─ for branches, → for outcomes
        - Use inline code formatting for function names, variables, and types.


        ---

        ## COMPRESSION RULE
        For every concept: "If I remove this, does understanding decrease?"
        YES = Keep. NO = Remove.
        Prefer minimum concepts over maximum information.

        ## CHAPTER GATE
        Do not proceed to the next chapter until all outputs of the current chapter are complete internally.
        """
    // swiftlint:enable line_length

    // MARK: Tag Vocabulary

    /// Available rendering tags. The LLM uses them when they add value.
    private static let tagVocabulary = """
        TAGS (optional — only when they earn their place):
        - <hl>text</hl> — Highlight a key identifier.
        - <critical>text</critical> — Bug or danger the developer must see.
        - <note>text</note> — Non-obvious behavior worth calling out.
        - <tip>text</tip> — Fix for a <critical>. Only use with <critical>.
        - <flow>diagram</flow> — Diagram using │ → ├─ └─. Only when prose \
        is insufficient.
        - <tldr>text</tldr> — One-sentence lead insight. Only when 4+ bullets.
        - <analogy>text</analogy> — Reserved. Do not use.
        Do NOT nest tags. Do NOT invent tags (unknown tags break rendering). \
        Most explanations need 0–1 tags.
        """

    // MARK: Code Health Prompt Augmentation

    /// Generate prompt augmentation based on the snippet's health classification.
    ///
    /// Returns an empty string for ``HealthTier/silent`` — the default. Higher
    /// tiers inject progressively stronger guidance, but the LLM is always
    /// allowed to dismiss parser evidence as partial-selection artifacts.
    static func healthPromptAugmentation(
        tier: HealthTier,
        hints: [DiagnosticHint]
    ) -> String {
        switch tier {
        case .silent:
            return ""

        case .observe:
            return """

                ---

                If you notice any issues, bugs, or anti-patterns in this code, \
                mention them briefly using <note> or <critical> tags — but only \
                if you are confident. Do not speculate about issues you are unsure of.
                """

        case .surface:
            var prompt = """

                ---

                STATIC ANALYSIS NOTES

                Tree-sitter parsing of this snippet in isolation detected \
                the following potential issues:
                """
            for hint in hints where hint.isInterior {
                prompt += "\n- Line \(hint.line): \(hint.description)"
            }
            prompt += """


                IMPORTANT: This snippet may have been selected from a larger file. \
                Some of these may be boundary artifacts from partial selection. \
                Use your judgment:
                - If an issue appears to be a real syntax or logic problem, \
                explain what is wrong and suggest a fix using <critical> and <tip> tags.
                - If an issue appears to be a partial-selection artifact \
                (e.g., missing opening brace because the function header was not selected), \
                ignore it and explain the code normally.
                """
            return prompt

        case .diagnose:
            var prompt = """

                ---

                STATIC ANALYSIS NOTES

                Tree-sitter parsing detected significant issues in this code:
                """
            for hint in hints {
                let marker = hint.isInterior ? "[interior]" : "[edge]"
                prompt += "\n- Line \(hint.line) \(marker): \(hint.description)"
            }
            prompt += """


                This code appears to have real syntax or structural problems. \
                Prioritize diagnosing these issues:
                - Use <critical> tags for each confirmed issue.
                - Use <tip> tags for each suggested fix.
                - After addressing the issues, briefly explain what the code \
                was trying to do.

                IMPORTANT: If any of these appear to be artifacts from partial \
                selection rather than real bugs, you may dismiss them. The parser \
                analyzed the snippet in isolation and may report false positives \
                at snippet boundaries.
                """
            return prompt
        }
    }
}

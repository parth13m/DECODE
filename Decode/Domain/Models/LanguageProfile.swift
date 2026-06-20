import Foundation

/// Language-specific guidance for Session Mode explanations.
///
/// Each profile provides contextual instructions that help the LLM produce
/// explanations tuned to a specific programming language's idioms, patterns,
/// and common points of confusion. Profiles are resolved from file extensions
/// and injected into the Session Mode system prompt.
///
/// Swift files do not receive a profile — their explanations use the default
/// prompt, which is already optimized for Swift.
struct LanguageProfile: Sendable {

    /// Display name shown in the prompt (e.g., "Python", "JavaScript").
    let displayName: String

    /// Concepts the LLM should emphasize when explaining code in this language.
    let emphasize: [String]

    /// Concepts the LLM should NOT spend time explaining (assumed knowledge).
    let deemphasize: [String]

    /// Additional language-specific instructions appended to the prompt.
    let guidance: [String]

    /// Build the prompt fragment for this language profile.
    ///
    /// Returns a string suitable for insertion into the system prompt,
    /// between the Session Context section and the style instructions.
    var promptFragment: String {
        var lines: [String] = []
        lines.append("## Language: \(displayName)")

        if !emphasize.isEmpty {
            lines.append("Focus on: \(emphasize.joined(separator: ", ")).")
        }

        if !deemphasize.isEmpty {
            lines.append("Do not over-explain: \(deemphasize.joined(separator: ", ")).")
        }

        for line in guidance {
            lines.append("- \(line)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Language Resolution

    /// Resolve a ``LanguageProfile`` from a file name's extension.
    ///
    /// Returns `nil` for Swift files (default prompt is already Swift-optimized)
    /// and for unrecognized extensions.
    static func from(fileName: String) -> LanguageProfile? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return profilesByExtension[ext]
    }

    // MARK: - Extension Mapping

    private static let profilesByExtension: [String: LanguageProfile] = {
        var map: [String: LanguageProfile] = [:]
        for ext in ["py"] { map[ext] = .python }
        for ext in ["js", "jsx", "mjs", "cjs"] { map[ext] = .javascript }
        for ext in ["ts", "tsx"] { map[ext] = .typescript }
        for ext in ["html", "htm"] { map[ext] = .html }
        for ext in ["css", "scss"] { map[ext] = .css }
        for ext in ["sql"] { map[ext] = .sql }
        for ext in ["java"] { map[ext] = .java }
        for ext in ["cs"] { map[ext] = .csharp }
        for ext in ["c", "h"] { map[ext] = .c }
        for ext in ["cpp", "cxx", "cc", "hpp", "hxx"] { map[ext] = .cpp }
        // Swift intentionally excluded — default prompt is already Swift-optimized.
        return map
    }()
}

// MARK: - Language Profiles

extension LanguageProfile {

    static let python = LanguageProfile(
        displayName: "Python",
        emphasize: [
            "decorator effects and how they transform the decorated function",
            "generator and iterator patterns",
            "context manager behavior (with statements)",
            "list/dict/set comprehension data flow",
            "dunder method purposes (__init__, __repr__, __enter__)",
            "type hint meaning and constraints"
        ],
        deemphasize: [
            "basic indentation rules",
            "import statement syntax",
            "self parameter on every method"
        ],
        guidance: [
            "When a function uses `self`, explain its role in the class — not what `self` means.",
            "For decorated functions, explain what the decorator changes about the function's behavior.",
            "For comprehensions, trace the data transformation step by step in the flow diagram."
        ]
    )

    static let javascript = LanguageProfile(
        displayName: "JavaScript",
        emphasize: [
            "closure scope and variable capture",
            "this binding rules and how they differ by call context",
            "Promise chains vs async/await execution order",
            "event loop implications of async code",
            "destructuring patterns and spread/rest operators",
            "module import/export relationships"
        ],
        deemphasize: [
            "var/let/const differences unless hoisting matters in this snippet",
            "basic arrow function syntax"
        ],
        guidance: [
            "If the code uses callbacks or Promises, trace the async execution order in the flow diagram.",
            "For React components, explain the render lifecycle and how props/state drive re-renders.",
            "For hooks (useState, useEffect, etc.), explain when the hook fires and what triggers it."
        ]
    )

    static let typescript = LanguageProfile(
        displayName: "TypeScript",
        emphasize: [
            "type narrowing and type guards",
            "generic constraints and how they restrict usage",
            "union and intersection type behavior",
            "utility types (Partial, Pick, Omit, Record) and what they produce",
            "interface vs type alias distinctions when relevant",
            "as const assertions and literal types"
        ],
        deemphasize: [
            "basic type annotations on primitives (string, number, boolean)",
            "import syntax"
        ],
        guidance: [
            "Explain what the types enforce and prevent, not just what they annotate.",
            "For generics, give a concrete example showing what T becomes with a real type.",
            "For React components, explain the render lifecycle and how props/state drive re-renders.",
            "For hooks (useState, useEffect, etc.), explain when the hook fires and what triggers it."
        ]
    )

    static let html = LanguageProfile(
        displayName: "HTML",
        emphasize: [
            "semantic element purpose (nav, article, section, aside, main)",
            "accessibility attributes (aria-*, role) and their impact",
            "form structure, input types, and validation attributes",
            "data attributes and their role in JavaScript interaction",
            "document structure and how this element fits in the page layout"
        ],
        deemphasize: [
            "basic tag open/close syntax",
            "self-closing tag rules",
            "standard attributes like class and id unless they serve a specific purpose"
        ],
        guidance: [
            "Explain the structural role of elements — why this element type was chosen and what it communicates to browsers and screen readers.",
            "For forms, explain how the form submits and what validation is applied.",
            "For layout elements, explain how this section fits in the overall page structure."
        ]
    )

    static let css = LanguageProfile(
        displayName: "CSS",
        emphasize: [
            "selector specificity and cascade order — which rule wins and why",
            "layout model (flexbox/grid) — how container and item properties interact",
            "responsive behavior (@media queries) and breakpoint logic",
            "custom properties (--var) scope and inheritance",
            "animation and transition mechanics — what triggers them, timing, easing",
            "pseudo-classes and pseudo-elements — when they activate"
        ],
        deemphasize: [
            "basic property syntax (property: value)",
            "color value formats",
            "units (px, em, rem) unless the choice of unit matters for the explanation"
        ],
        guidance: [
            "For selectors, explain WHY a rule applies (specificity, cascade position) not just what it targets.",
            "For layout properties, explain the relationship between container and children — e.g., flex container vs flex items.",
            "For responsive rules, explain what changes at each breakpoint and why.",
            "Explain how properties interact with each other, not each property in isolation."
        ]
    )

    static let sql = LanguageProfile(
        displayName: "SQL",
        emphasize: [
            "query execution order (FROM → WHERE → GROUP BY → HAVING → SELECT → ORDER BY)",
            "join semantics — what rows survive each join type",
            "subquery vs CTE tradeoffs",
            "NULL handling behavior in comparisons and aggregations",
            "index usage implications — will this query use an index or scan"
        ],
        deemphasize: [
            "basic SELECT/INSERT/UPDATE/DELETE syntax",
            "standard SQL keywords"
        ],
        guidance: [
            "Trace the logical execution order — show how the query engine processes each clause, not just the final result.",
            "For joins, explain which rows from each table survive and why.",
            "For aggregations, explain what happens to individual rows as they are grouped.",
            "If a query has performance implications (missing index, full table scan), mention it."
        ]
    )

    static let java = LanguageProfile(
        displayName: "Java",
        emphasize: [
            "inheritance and interface implementation — what contract this class fulfills",
            "access modifiers and encapsulation intent",
            "generics and type erasure implications",
            "exception handling patterns (checked vs unchecked)",
            "Stream API and lambda expression data flow",
            "annotation behavior (@Override, @Autowired, custom annotations)"
        ],
        deemphasize: [
            "basic class/method declaration syntax",
            "getter/setter boilerplate",
            "import statements"
        ],
        guidance: [
            "Explain the design pattern being used and why the code is structured this way.",
            "For Spring/framework annotations, explain what the annotation triggers at runtime.",
            "For Stream operations, trace the data pipeline step by step in the flow diagram."
        ]
    )

    static let csharp = LanguageProfile(
        displayName: "C#",
        emphasize: [
            "LINQ query semantics and execution (deferred vs immediate)",
            "async/await and Task execution flow",
            "nullable reference types and ? annotations",
            "pattern matching (switch expressions, is patterns)",
            "IDisposable and using/await using patterns",
            "record and struct value semantics"
        ],
        deemphasize: [
            "basic property syntax (get; set;)",
            "namespace declarations",
            "standard using directives"
        ],
        guidance: [
            "For async code, trace the execution flow showing where awaits suspend and resume.",
            "For LINQ, explain whether execution is deferred or immediate and what that means for performance.",
            "For dependency injection patterns, explain what gets injected and when."
        ]
    )

    static let c = LanguageProfile(
        displayName: "C",
        emphasize: [
            "pointer arithmetic and memory layout",
            "ownership and lifetime — who allocates and who must free",
            "undefined behavior risks in this code",
            "preprocessor macro expansion and conditional compilation",
            "struct layout and padding implications"
        ],
        deemphasize: [
            "basic type declarations",
            "semicolons and brace syntax",
            "standard #include files"
        ],
        guidance: [
            "Always highlight memory safety implications — if memory is allocated, explain who frees it.",
            "Flag potential undefined behavior (buffer overflows, use-after-free, null dereference).",
            "For pointer operations, show what the pointer points to at each step in the flow diagram."
        ]
    )

    static let cpp = LanguageProfile(
        displayName: "C++",
        emphasize: [
            "RAII patterns and resource ownership",
            "smart pointer semantics (unique_ptr, shared_ptr, weak_ptr)",
            "move semantics and when moves vs copies occur",
            "virtual dispatch mechanics and vtable implications",
            "template instantiation — what concrete types are generated",
            "const correctness and reference semantics"
        ],
        deemphasize: [
            "basic type declarations",
            "semicolons and brace syntax",
            "standard #include files"
        ],
        guidance: [
            "Explain ownership transfer — when objects move vs copy and what happens to the source.",
            "For templates, show a concrete instantiation with real types.",
            "Flag potential undefined behavior (dangling references, use-after-move, buffer overflows).",
            "For virtual methods, explain which override gets called and why."
        ]
    )
}

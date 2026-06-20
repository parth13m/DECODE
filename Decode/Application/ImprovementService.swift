import Foundation

/// The parsed result of an AI-generated code improvement.
struct ImprovementResult: Sendable {
    /// A brief explanation of what changed and why the improved version is better.
    let summary: String
    /// The improved code, ready to copy or paste into the editor.
    let improvedCode: String
}

/// Builds improvement prompts and parses structured AI responses.
///
/// Stateless service used by ``ExplanationHUDViewModel`` to request code
/// improvements after an explanation has been generated. Uses custom XML-like
/// tags (`<improvement_summary>`, `<improved_code>`) that are consistent with
/// Decode's existing tag vocabulary approach.
enum ImprovementService {

    // MARK: - Prompt

    /// System prompt for code improvement requests.
    ///
    /// Instructs the AI to return a structured response with exactly two tagged
    /// sections. No markdown headings — the HUD renderer uses
    /// `.inlineOnlyPreservingWhitespace` which does not support `##`.
    static let systemPrompt = """
        You are Decode, a code improvement assistant for macOS. The user has \
        selected code and already received an explanation. Now they want an \
        improved version.

        TASK:
        - Analyze the code for meaningful improvements in: readability, \
        maintainability, safety, performance, API design, naming clarity, \
        simplicity, or code structure.
        - Preserve the original behavior exactly. Do NOT change what the code does.
        - Focus on the most impactful changes. Do not rewrite for the sake of rewriting.

        QUALITY THRESHOLD:
        A change qualifies as an improvement ONLY if it meaningfully improves \
        at least one of: readability, maintainability, safety, performance, \
        API design, naming clarity, simplicity, or code structure.

        The following do NOT qualify as improvements:
        - Adding, removing, or modifying comments only
        - Changing whitespace or formatting only
        - Reordering code without structural benefit
        - Renaming variables to synonyms of equal clarity
        - Adding type annotations that the compiler already infers

        If no meaningful improvement exists, be honest. Do NOT force changes.

        RESPONSE FORMAT:
        If you found meaningful improvements, respond with both tags:

        <improvement_summary>
        Brief explanation of what you changed and why. 2-4 sentences maximum.
        </improvement_summary>
        <improved_code>
        The improved code here. Output ONLY the code, no backticks, no language labels.
        </improved_code>

        If no meaningful improvement exists, respond with ONLY the summary tag:

        <improvement_summary>
        No meaningful improvement found.

        The current implementation is already clear and appropriate for its purpose.
        </improvement_summary>

        Do NOT include an <improved_code> tag when no meaningful improvement exists.

        RULES:
        - Do NOT use markdown fenced code blocks (```). Output raw code inside the tag.
        - Do NOT use markdown headings (## or ###).
        - Do NOT add comments as improvements. Comments are documentation, not code quality.
        - Do NOT add features, error handling, or validation beyond what the original has.
        - Do NOT change function signatures, parameter names, or return types unless \
        they are clearly wrong.
        - Keep the improved code the same language as the original.
        - Preserve meaningful comments from the original code.
        """

    // MARK: - Context-Aware Prompt (Session Mode)

    /// Build an improvement system prompt enriched with session context.
    ///
    /// Reuses the exact ``SessionContext`` that was selected for the original
    /// explanation — same tier, same outline, same entity source. No file I/O,
    /// no re-parsing, no duplicate tier selection.
    ///
    /// Only called for Session Improve. Selection Improve continues to use
    /// the static ``systemPrompt``.
    static func contextAwareSystemPrompt(context: SessionContext) -> String {
        let lang = codeFenceLanguage(for: context.fileName)

        var prompt = """
            You are Decode, a code improvement assistant for macOS. The user \
            selected code inside a file they have open in Session Mode and \
            already received an explanation. Now they want an improved version.

            FILE: \(context.fileName) (\(context.entityCount) entities)

            FILE STRUCTURE:
            ```
            \(context.fileStructureOutline)
            ```
            """

        // Tier-specific source context (mirrors ContextBuilderService tiers).
        if !context.snippetLocationDescription.isEmpty {
            prompt += "\n\nSNIPPET LOCATION:\n\(context.snippetLocationDescription)"
        }

        if let entitySource = context.containingEntitySource {
            // Tier 1: entity source.
            prompt += """

                \nCONTAINING ENTITY SOURCE:
                ```\(lang)
                \(entitySource)
                ```

                Use the containing entity to understand the snippet's role, types, \
                and naming conventions. Improvements must be consistent with the \
                surrounding code style.
                """
        } else if let fallback = context.fallbackFileContent {
            // Tier 2: full file (small files).
            prompt += """

                \nFULL FILE CONTENT:
                ```\(lang)
                \(fallback)
                ```

                Use the full file to understand types, imports, and conventions. \
                Improvements must be consistent with the file's existing style.
                """
        } else if let surrounding = context.surroundingCode,
                  let lineRange = context.snippetLineRange {
            // Tier 2.5: surrounding code window.
            prompt += """

                \nSURROUNDING CODE (lines \(lineRange.lowerBound)-\(lineRange.upperBound) and neighbors):
                ```\(lang)
                \(surrounding)
                ```
                """

            if let above = context.nearestEntityAbove {
                prompt += "\n\nNEAREST ENTITY ABOVE:\n`\(above.signature)` [lines \(above.startLine)-\(above.endLine)]"
            }
            if let below = context.nearestEntityBelow {
                prompt += "\n\nNEAREST ENTITY BELOW:\n`\(below.signature)` [lines \(below.startLine)-\(below.endLine)]"
            }

            prompt += """

                \nUse the surrounding code and file structure to understand the \
                snippet's context. Improvements must be consistent with neighboring code.
                """
        } else {
            // Tier 3: outline only.
            prompt += """

                \nUse the file structure outline to understand the snippet's role \
                within the file.
                """
        }

        // Language-specific guidance.
        if let langGuide = context.languageGuidance {
            prompt += "\n\n\(langGuide)"
        }

        // Shared improvement instructions (same rules as the generic prompt).
        prompt += """

            \nTASK:
            - Analyze the code for meaningful improvements in: readability, \
            maintainability, safety, performance, API design, naming clarity, \
            simplicity, or code structure.
            - Preserve the original behavior exactly. Do NOT change what the code does.
            - Focus on the most impactful changes. Do not rewrite for the sake of rewriting.

            QUALITY THRESHOLD:
            A change qualifies as an improvement ONLY if it meaningfully improves \
            at least one of: readability, maintainability, safety, performance, \
            API design, naming clarity, simplicity, or code structure.

            The following do NOT qualify as improvements:
            - Adding, removing, or modifying comments only
            - Changing whitespace or formatting only
            - Reordering code without structural benefit
            - Renaming variables to synonyms of equal clarity
            - Adding type annotations that the compiler already infers

            If no meaningful improvement exists, be honest. Do NOT force changes.

            RESPONSE FORMAT:
            If you found meaningful improvements, respond with both tags:

            <improvement_summary>
            Brief explanation of what you changed and why. 2-4 sentences maximum.
            </improvement_summary>
            <improved_code>
            The improved code here. Output ONLY the code, no backticks, no language labels.
            </improved_code>

            If no meaningful improvement exists, respond with ONLY the summary tag:

            <improvement_summary>
            No meaningful improvement found.

            The current implementation is already clear and appropriate for its purpose.
            </improvement_summary>

            Do NOT include an <improved_code> tag when no meaningful improvement exists.

            RULES:
            - Do NOT use markdown fenced code blocks (```). Output raw code inside the tag.
            - Do NOT use markdown headings (## or ###).
            - Do NOT add comments as improvements. Comments are documentation, not code quality.
            - Do NOT add features, error handling, or validation beyond what the original has.
            - Do NOT change function signatures, parameter names, or return types unless \
            they are clearly wrong.
            - Keep the improved code the same language as the original.
            - Preserve meaningful comments from the original code.
            """

        return prompt
    }

    /// Derive a code-fence language hint from a filename's extension.
    private static func codeFenceLanguage(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let map: [String: String] = [
            "swift": "swift", "js": "javascript", "jsx": "javascript",
            "ts": "typescript", "tsx": "typescript", "py": "python",
            "rb": "ruby", "go": "go", "rs": "rust", "java": "java",
            "kt": "kotlin", "c": "c", "cpp": "cpp", "h": "c",
            "hpp": "cpp", "cs": "csharp", "m": "objectivec",
            "mm": "objectivec", "sh": "bash", "zsh": "bash",
            "html": "html", "css": "css", "sql": "sql",
            "php": "php", "dart": "dart", "scala": "scala",
        ]
        return map[ext] ?? ""
    }

    // MARK: - Mode

    /// Build the compound analytics mode for an improvement request.
    ///
    /// Returns `"selection_improve"` or `"session_improve"` so the server
    /// logs the request distinctly from explanations without requiring
    /// backend schema changes.
    static func improvementMode(from originalMode: String?) -> String {
        guard let mode = originalMode else { return "improve" }
        return "\(mode)_improve"
    }

    // MARK: - Response Parsing

    /// Parse a raw AI response into an ``ImprovementResult``.
    ///
    /// Extracts content between `<improvement_summary>...</improvement_summary>`
    /// and `<improved_code>...</improved_code>` tags. Falls back gracefully if
    /// tags are missing — treats the entire response as summary with no code.
    static func parseResponse(_ rawText: String) -> ImprovementResult {
        let summary = extractTagContent(from: rawText, tag: "improvement_summary")
            ?? "Improvement generated."
        let code = extractTagContent(from: rawText, tag: "improved_code")
            ?? ""

        return ImprovementResult(
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            improvedCode: code.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Extract text content between opening and closing XML-like tags.
    ///
    /// Returns `nil` if the tag is not found. Handles whitespace around tags.
    private static func extractTagContent(from text: String, tag: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"

        guard let openRange = text.range(of: openTag),
              let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex)
        else {
            return nil
        }

        return String(text[openRange.upperBound..<closeRange.lowerBound])
    }
}

import Foundation

/// Adaptive Representation Engine (ARE) — Phase 1.
///
/// Analyzes a code snippet and provides advisory representation guidance
/// to the LLM. The guidance suggests which representation *might* help
/// the user understand the code faster — but never commands it.
///
/// ARE does not generate visuals, add tags, or change the UI. It contributes
/// a short paragraph to the system prompt alongside AEE, Code Health, and
/// session context.
///
/// ## Philosophy
/// - Understanding is mandatory. Representation is optional.
/// - Every representation must earn its place.
/// - The LLM remains free to ignore guidance.
/// - Simple code gets no guidance (empty string).
///
/// ## Signals
/// Phase 1 detects 6 patterns:
/// 1. Recursive algorithms → concrete example trace
/// 2. Complex generic nesting → data shape / type tree
/// 3. State management patterns → state transitions
/// 4. Async-heavy flows → timeline / event sequence
/// 5. Enums with multiple cases → comparison-style
/// 6. Simple / short snippets → no guidance
enum RepresentationGuidance {

    /// Generate representation guidance for a code snippet.
    ///
    /// Returns a short advisory paragraph to append to the system prompt,
    /// or an empty string when no guidance is appropriate.
    ///
    /// - Parameters:
    ///   - snippet: The user's selected code text.
    ///   - framework: The detected language family, if available.
    ///   - containingEntityType: The entity type of the code entity that
    ///     contains the snippet, if matched during workspace resolution.
    static func guidance(
        snippet: String,
        framework: ExplanationFramework?,
        containingEntityType: EntityType?
    ) -> String {
        // Signal 6: Simple snippets get no guidance.
        // Short code is best served by AEE's adaptive depth alone.
        let meaningfulLines = snippet
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if meaningfulLines.count <= 4 {
            return ""
        }

        // Check signals in priority order.
        // Only one signal fires — the first match wins.
        // Priority: recursion > complex generics > state management > async > enum.

        if detectsRecursion(snippet) {
            return "\n\nThis code is recursive — include a worked example trace."
        }

        if detectsComplexGenerics(snippet) {
            return "\n\nThis code has complex type nesting — show the data shape."
        }

        if detectsStateManagement(snippet, entityType: containingEntityType) {
            return "\n\nThis code manages state transitions — map the states and triggers."
        }

        if detectsAsyncFlow(snippet, framework: framework) {
            return "\n\nThis code chains async operations — show the event sequence."
        }

        if detectsEnumWithCases(snippet, entityType: containingEntityType) {
            return "\n\nThis code defines multiple cases — compare them concisely."
        }

        // No signal matched — no guidance. AEE handles it.
        return ""
    }

    // MARK: - Signal Detectors

    /// Detect recursive algorithms: the snippet contains a call to itself.
    ///
    /// Looks for function/method definitions that reference their own name
    /// in the body. Also detects common recursive patterns.
    private static func detectsRecursion(_ snippet: String) -> Bool {
        // Extract function/method name from common declaration patterns.
        let defPatterns: [(pattern: String, nameGroup: Int)] = [
            (#"(?:func|def|function)\s+(\w+)"#, 1),
            (#"(?:const|let|var)\s+(\w+)\s*="#, 1),
        ]

        for (pattern, group) in defPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: snippet,
                    range: NSRange(snippet.startIndex..., in: snippet)
                  ),
                  let nameRange = Range(match.range(at: group), in: snippet) else {
                continue
            }

            let funcName = String(snippet[nameRange])
            guard funcName.count >= 2 else { continue }

            // Check if the function name appears again in the body
            // (after the declaration line).
            let lines = snippet.components(separatedBy: "\n")
            guard lines.count >= 2 else { continue }

            let body = lines.dropFirst().joined(separator: "\n")
            // Look for a call: funcName followed by ( — not just the name
            // appearing in a comment or string.
            let callPattern = "\\b\(NSRegularExpression.escapedPattern(for: funcName))\\s*\\("
            if body.range(of: callPattern, options: .regularExpression) != nil {
                return true
            }
        }

        return false
    }

    /// Detect complex generic/type nesting: deeply nested angle brackets
    /// or type signatures that require mental parsing.
    ///
    /// Fires when angle bracket nesting depth reaches 3+.
    private static func detectsComplexGenerics(_ snippet: String) -> Bool {
        var maxDepth = 0
        var depth = 0

        for char in snippet {
            if char == "<" {
                depth += 1
                maxDepth = max(maxDepth, depth)
            } else if char == ">" {
                depth = max(0, depth - 1)
            }
        }

        return maxDepth >= 3
    }

    /// Detect state management patterns: enums used as state, reducers,
    /// switch statements over state, state machine-like structures.
    private static func detectsStateManagement(
        _ snippet: String,
        entityType: EntityType?
    ) -> Bool {
        let stateKeywords = [
            "state", "State", "status", "Status",
            "phase", "Phase", "mode", "Mode",
        ]
        let transitionKeywords = [
            "transition", "Transition",
            "setState", "dispatch",
            "reducer", "Reducer",
        ]

        let hasStateKeyword = stateKeywords.contains { snippet.contains($0) }
        let hasTransitionKeyword = transitionKeywords.contains { snippet.contains($0) }

        // Strong signal: state keyword + switch/case pattern.
        if hasStateKeyword {
            let hasSwitchCase = snippet.contains("switch ") && snippet.contains("case ")
            if hasSwitchCase { return true }
        }

        // Strong signal: explicit transition keyword.
        if hasTransitionKeyword && hasStateKeyword { return true }

        // Moderate signal: enum entity type + state keyword in content.
        if entityType == .enum && hasStateKeyword { return true }

        return false
    }

    /// Detect async-heavy flows: multiple await points, promise chains,
    /// callback nesting, or event listener patterns.
    private static func detectsAsyncFlow(
        _ snippet: String,
        framework: ExplanationFramework?
    ) -> Bool {
        var asyncSignals = 0

        // Count await occurrences (Swift, JS/TS, Python).
        let awaitMatches = snippet.components(separatedBy: "await ").count - 1
        asyncSignals += awaitMatches

        // Promise chains (.then).
        let thenCount = snippet.components(separatedBy: ".then(").count - 1
        asyncSignals += thenCount

        // Async function declarations.
        if snippet.contains("async func") || snippet.contains("async function")
            || snippet.contains("async def") {
            asyncSignals += 1
        }

        // Callback patterns.
        let callbackPatterns = ["setTimeout(", "setInterval(", "addEventListener("]
        for pattern in callbackPatterns where snippet.contains(pattern) {
            asyncSignals += 1
        }

        // Lifecycle hooks (React).
        if framework == .lifecycle {
            let hooks = ["useEffect", "useLayoutEffect", "componentDidMount",
                         "componentDidUpdate", "componentWillUnmount"]
            for hook in hooks where snippet.contains(hook) {
                asyncSignals += 1
            }
        }

        // Need multiple async signals — a single await is not "async-heavy."
        return asyncSignals >= 3
    }

    /// Detect enums with multiple distinct cases worth comparing.
    private static func detectsEnumWithCases(
        _ snippet: String,
        entityType: EntityType?
    ) -> Bool {
        // Direct signal: entity type is enum.
        if entityType == .enum {
            // Count case declarations to ensure there are multiple worth comparing.
            let caseCount = snippet.components(separatedBy: "\n")
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("case ")
                }
                .count
            return caseCount >= 3
        }

        // Content heuristic: enum-like declaration + multiple cases.
        let enumDecl = snippet.contains("enum ") || snippet.contains("sealed class")
            || snippet.contains("union type") || snippet.contains("type ")
                && snippet.contains(" = ")

        if enumDecl {
            let caseCount = snippet.components(separatedBy: "\n")
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("case ") || trimmed.contains("| ")
                }
                .count
            return caseCount >= 3
        }

        return false
    }
}

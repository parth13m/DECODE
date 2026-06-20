import Foundation

/// Assembles snippet-anchored AI prompt context from a Session's knowledge state.
///
/// Instead of dumping the entire file into the system prompt, v2 locates the
/// user's selected snippet within the file's parsed entities and builds a
/// focused context: the containing entity's source, parent type signature,
/// sibling method signatures, and a structural outline of the file with the
/// snippet's location marked.
///
/// ## Fallback Tiers
/// 1. **Entity match** — snippet found inside a `ParsedEntity`. Full focused
///    context: containing entity source, parent, siblings, marked outline.
/// 2. **Small file fallback** — snippet not matched, file ≤ 200 lines. Send
///    full file content (v1 behavior). Small files don't suffer token bloat.
/// 2.5. **Local context fallback** — snippet not matched, file > 200 lines,
///    but snippet located by text search. Surrounding lines + nearest entity
///    signatures + positional outline marker.
/// 3. **Large file fallback** — snippet not matched, file > 200 lines, snippet
///    not found in file. Structural outline only (no raw source).
struct ContextBuilderService: Sendable {

    /// Maximum file line count for the "send full file" fallback.
    private static let smallFileThreshold = 200

    /// Lines of context to include above and below the snippet (Tier 2.5).
    private static let surroundingWindowRadius = 30

    // MARK: - Context Assembly

    /// Build a ``SessionContext`` anchored to the user's selected snippet.
    ///
    /// Reads the file from disk, locates the snippet within the parsed entities,
    /// and assembles the appropriate context tier. Returns `nil` only if the
    /// file cannot be read.
    func buildContext(
        session: Session,
        parsedEntities: [ParsedEntity],
        snippet: String
    ) -> SessionContext? {
        let url = URL(fileURLWithPath: session.filePath)
        guard let fileContent = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let languageGuidance = LanguageProfile.from(fileName: session.fileName)?.promptFragment

        let location = locateSnippet(snippet: snippet, entities: parsedEntities)

        if let location {
            return buildEntityMatchedContext(
                session: session,
                parsedEntities: parsedEntities,
                location: location,
                languageGuidance: languageGuidance
            )
        }

        // Fallback: no entity match.
        let lineCount = fileContent.components(separatedBy: "\n").count
        let outline = buildStructureOutline(
            entities: parsedEntities,
            markedEntityStableId: nil
        )

        if lineCount <= Self.smallFileThreshold {
            // Tier 2: small file — include full content.
            // Try to locate the snippet within the file so we can insert
            // selection markers and give the model a clear focus point.
            let trimmedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            let fileLines = fileContent.components(separatedBy: "\n")

            if !trimmedSnippet.isEmpty,
               let snippetRange = fileContent.range(of: trimmedSnippet) {
                // Found snippet — insert markers and compute line range.
                let beforeSnippet = fileContent[fileContent.startIndex..<snippetRange.lowerBound]
                let snippetStartLine = beforeSnippet.components(separatedBy: "\n").count
                let snippetLineCount = fileContent[snippetRange].components(separatedBy: "\n").count
                let snippetEndLine = snippetStartLine + snippetLineCount - 1

                // Insert selection markers into the file content.
                var markedLines = fileLines
                markedLines.insert("// ← SELECTED END", at: snippetEndLine)
                markedLines.insert("// ← SELECTED START", at: snippetStartLine - 1)
                let markedContent = markedLines.joined(separator: "\n")

                let markedOutline = buildStructureOutlineWithLineMarker(
                    entities: parsedEntities,
                    snippetLineRange: snippetStartLine...snippetEndLine
                )

                return SessionContext(
                    sessionId: session.id,
                    fileName: session.fileName,
                    entityCount: parsedEntities.count,
                    fileStructureOutline: markedOutline,
                    snippetLocationDescription: "Lines \(snippetStartLine)–\(snippetEndLine).",
                    containingEntitySource: nil,
                    hasSourceInContext: true,
                    fallbackFileContent: markedContent,
                    surroundingCode: nil,
                    snippetLineRange: snippetStartLine...snippetEndLine,
                    nearestEntityAbove: nil,
                    nearestEntityBelow: nil,
                    languageGuidance: languageGuidance
                )
            }

            // Snippet not found in file — send full file without markers.
            // hasSourceInContext is false so the snippet remains in the user message.
            return SessionContext(
                sessionId: session.id,
                fileName: session.fileName,
                entityCount: parsedEntities.count,
                fileStructureOutline: outline,
                snippetLocationDescription: "",
                containingEntitySource: nil,
                hasSourceInContext: false,
                fallbackFileContent: fileContent,
                surroundingCode: nil,
                snippetLineRange: nil,
                nearestEntityAbove: nil,
                nearestEntityBelow: nil,
                languageGuidance: languageGuidance
            )
        }

        // Tier 2.5: large file — try to locate snippet by text search.
        if let localContext = buildLocalContext(
            snippet: snippet,
            fileContent: fileContent,
            fileLines: fileContent.components(separatedBy: "\n"),
            entities: parsedEntities
        ) {
            let markedOutline = buildStructureOutlineWithLineMarker(
                entities: parsedEntities,
                snippetLineRange: localContext.snippetLineRange
            )
            return SessionContext(
                sessionId: session.id,
                fileName: session.fileName,
                entityCount: parsedEntities.count,
                fileStructureOutline: markedOutline,
                snippetLocationDescription: localContext.locationDescription,
                containingEntitySource: nil,
                hasSourceInContext: true,
                fallbackFileContent: nil,
                surroundingCode: localContext.surroundingCode,
                snippetLineRange: localContext.snippetLineRange,
                nearestEntityAbove: localContext.entityAbove,
                nearestEntityBelow: localContext.entityBelow,
                languageGuidance: languageGuidance
            )
        }

        // Tier 3: large file, snippet not found — outline only.
        return SessionContext(
            sessionId: session.id,
            fileName: session.fileName,
            entityCount: parsedEntities.count,
            fileStructureOutline: outline,
            snippetLocationDescription: "",
            containingEntitySource: nil,
            hasSourceInContext: false,
            fallbackFileContent: nil,
            surroundingCode: nil,
            snippetLineRange: nil,
            nearestEntityAbove: nil,
            nearestEntityBelow: nil,
            languageGuidance: languageGuidance
        )
    }

    /// Build focused context when the snippet was matched to an entity.
    private func buildEntityMatchedContext(
        session: Session,
        parsedEntities: [ParsedEntity],
        location: SnippetLocation,
        languageGuidance: String?
    ) -> SessionContext {
        let containing = location.containingEntity

        // Resolve parent entity (for location description only — the outline
        // already shows the full parent/child hierarchy).
        let parent: ParsedEntity? = {
            guard let pid = containing.parentStableId else { return nil }
            return parsedEntities.first { $0.entity.stableId == pid }
        }()

        // Build location description.
        let entityKind = containing.entity.entityType.rawValue
        let locationDesc: String
        if let parent {
            locationDesc = "Inside `\(containing.entity.name)`, a \(entityKind) of `\(parent.entity.name)` (lines \(containing.startLine)-\(containing.endLine))."
        } else {
            locationDesc = "Inside `\(containing.entity.name)`, a top-level \(entityKind) (lines \(containing.startLine)-\(containing.endLine))."
        }

        let outline = buildStructureOutline(
            entities: parsedEntities,
            markedEntityStableId: containing.entity.stableId
        )

        return SessionContext(
            sessionId: session.id,
            fileName: session.fileName,
            entityCount: parsedEntities.count,
            fileStructureOutline: outline,
            snippetLocationDescription: locationDesc,
            containingEntitySource: containing.sourceText,
            hasSourceInContext: true,
            fallbackFileContent: nil,
            surroundingCode: nil,
            snippetLineRange: nil,
            nearestEntityAbove: nil,
            nearestEntityBelow: nil,
            languageGuidance: languageGuidance
        )
    }

    // MARK: - Snippet Location

    /// Match a snippet to the most specific entity that contains it.
    ///
    /// Strategy:
    /// 1. Find all entities whose `sourceText` contains the snippet verbatim.
    /// 2. If multiple match, prefer the smallest (most specific) entity.
    /// 3. If none match with exact containment, try normalized whitespace matching.
    private func locateSnippet(
        snippet: String,
        entities: [ParsedEntity]
    ) -> SnippetLocation? {
        let trimmedSnippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSnippet.isEmpty else { return nil }

        // Exact containment: entity source contains the snippet verbatim.
        var matches = entities.filter { $0.sourceText.contains(trimmedSnippet) }

        // If no exact match, try normalized whitespace.
        if matches.isEmpty {
            let normalizedSnippet = normalizeWhitespace(trimmedSnippet)
            matches = entities.filter {
                normalizeWhitespace($0.sourceText).contains(normalizedSnippet)
            }
        }

        guard !matches.isEmpty else { return nil }

        // Prefer the smallest (most specific) entity.
        let best = matches.min { a, b in
            a.sourceText.count < b.sourceText.count
        }!

        return SnippetLocation(containingEntity: best)
    }

    /// Collapse runs of whitespace into single spaces for fuzzy matching.
    private func normalizeWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Local Context (Tier 2.5)

    /// Result of locating a snippet by text search in the file.
    private struct LocalContext {
        let snippetLineRange: ClosedRange<Int>
        let surroundingCode: String
        let locationDescription: String
        let entityAbove: NearestEntity?
        let entityBelow: NearestEntity?
    }

    /// Locate the snippet in the raw file content and extract surrounding context.
    ///
    /// Returns `nil` if the snippet text cannot be found in the file.
    private func buildLocalContext(
        snippet: String,
        fileContent: String,
        fileLines: [String],
        entities: [ParsedEntity]
    ) -> LocalContext? {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Find snippet in file content.
        guard let range = fileContent.range(of: trimmed) else { return nil }

        // Convert string position to 1-based line numbers.
        let beforeSnippet = fileContent[fileContent.startIndex..<range.lowerBound]
        let snippetStartLine = beforeSnippet.components(separatedBy: "\n").count
        let snippetText = fileContent[range]
        let snippetLineCount = snippetText.components(separatedBy: "\n").count
        let snippetEndLine = snippetStartLine + snippetLineCount - 1
        let snippetLineRange = snippetStartLine...snippetEndLine

        // Extract surrounding window.
        let windowStart = max(1, snippetStartLine - Self.surroundingWindowRadius)
        let windowEnd = min(fileLines.count, snippetEndLine + Self.surroundingWindowRadius)
        let windowLines = fileLines[(windowStart - 1)...(windowEnd - 1)]
        let surroundingCode = windowLines.joined(separator: "\n")

        // Find nearest entities.
        let entityAbove = entities
            .filter { $0.endLine < snippetStartLine }
            .max { $0.endLine < $1.endLine }
            .map { NearestEntity(signature: $0.signature, startLine: $0.startLine, endLine: $0.endLine) }

        let entityBelow = entities
            .filter { $0.startLine > snippetEndLine }
            .min { $0.startLine < $1.startLine }
            .map { NearestEntity(signature: $0.signature, startLine: $0.startLine, endLine: $0.endLine) }

        // Build location description.
        var locationDesc = "Lines \(snippetStartLine)–\(snippetEndLine)"
        if let above = entityAbove, let below = entityBelow {
            locationDesc += ", between `\(above.signature)` (ends line \(above.endLine)) and `\(below.signature)` (starts line \(below.startLine))."
        } else if let above = entityAbove {
            locationDesc += ", after `\(above.signature)` (ends line \(above.endLine))."
        } else if let below = entityBelow {
            locationDesc += ", before `\(below.signature)` (starts line \(below.startLine))."
        } else {
            locationDesc += "."
        }

        return LocalContext(
            snippetLineRange: snippetLineRange,
            surroundingCode: surroundingCode,
            locationDescription: locationDesc,
            entityAbove: entityAbove,
            entityBelow: entityBelow
        )
    }

    // MARK: - Structure Outline

    /// Build a hierarchical outline of the file's entities.
    ///
    /// Top-level entities are unindented. Members are indented under their
    /// parent. The entity matching `markedEntityStableId` gets a `← selected`
    /// marker so the LLM can see exactly where the snippet lives.
    private func buildStructureOutline(
        entities: [ParsedEntity],
        markedEntityStableId: String?
    ) -> String {
        var lines: [String] = []

        let topLevel = entities.filter { $0.isTopLevel }
        let children = entities.filter { !$0.isTopLevel }

        var childrenByParent: [String: [ParsedEntity]] = [:]
        for child in children {
            if let pid = child.parentStableId {
                childrenByParent[pid, default: []].append(child)
            }
        }

        for parent in topLevel {
            let marker = parent.entity.stableId == markedEntityStableId ? "  ← selected" : ""
            lines.append("\(parent.signature) [lines \(parent.startLine)-\(parent.endLine)]\(marker)")

            let kids = childrenByParent[parent.entity.stableId] ?? []
            for child in kids {
                let childMarker = child.entity.stableId == markedEntityStableId ? "  ← selected" : ""
                lines.append("  \(child.signature) [lines \(child.startLine)-\(child.endLine)]\(childMarker)")
            }
        }

        // Orphaned children (parent not in top-level list).
        let knownParents = Set(topLevel.map(\.entity.stableId))
        let orphans = children.filter {
            guard let pid = $0.parentStableId else { return false }
            return !knownParents.contains(pid)
        }
        for orphan in orphans {
            let marker = orphan.entity.stableId == markedEntityStableId ? "  ← selected" : ""
            lines.append("\(orphan.signature) [lines \(orphan.startLine)-\(orphan.endLine)]\(marker)")
        }

        return lines.joined(separator: "\n")
    }

    /// Build an outline with a positional marker for the snippet's line range.
    ///
    /// Unlike `buildStructureOutline(markedEntityStableId:)` which marks a
    /// matched entity, this inserts a `← snippet here` line at the correct
    /// position based on line numbers. Used by Tier 2.5 when no entity match.
    private func buildStructureOutlineWithLineMarker(
        entities: [ParsedEntity],
        snippetLineRange: ClosedRange<Int>
    ) -> String {
        let baseOutline = buildStructureOutline(
            entities: entities,
            markedEntityStableId: nil
        )

        // Find the right position to insert the marker among outline lines.
        // Each outline line has "[lines N-M]" — insert the marker after the
        // last entity that ends before the snippet.
        var outlineLines = baseOutline.components(separatedBy: "\n")
        let marker = "  ← snippet here (lines \(snippetLineRange.lowerBound)-\(snippetLineRange.upperBound))"

        // Find insertion index: after the last entity ending before snippet start.
        var insertIndex = outlineLines.count
        for (i, line) in outlineLines.enumerated().reversed() {
            // Extract end line from "[lines N-M]" pattern.
            if let endLineMatch = line.range(of: #"\[lines \d+-(\d+)\]"#, options: .regularExpression) {
                let matchStr = String(line[endLineMatch])
                if let dashRange = matchStr.range(of: "-"),
                   let closeBracket = matchStr.range(of: "]") {
                    let endLineStr = String(matchStr[dashRange.upperBound..<closeBracket.lowerBound])
                    if let endLine = Int(endLineStr), endLine < snippetLineRange.lowerBound {
                        insertIndex = i + 1
                        break
                    }
                }
            }
        }

        outlineLines.insert(marker, at: insertIndex)
        return outlineLines.joined(separator: "\n")
    }

    // MARK: - Language Detection

    /// Map a file extension to a markdown code-fence language hint.
    private static let extensionToLanguage: [String: String] = [
        "swift": "swift", "js": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript", "py": "python",
        "rb": "ruby", "go": "go", "rs": "rust", "java": "java",
        "kt": "kotlin", "c": "c", "cpp": "cpp", "h": "c",
        "hpp": "cpp", "cs": "csharp", "m": "objectivec",
        "mm": "objectivec", "sh": "bash", "zsh": "bash",
        "json": "json", "yaml": "yaml", "yml": "yaml",
        "toml": "toml", "xml": "xml", "html": "html",
        "css": "css", "scss": "scss", "sql": "sql",
        "md": "markdown", "r": "r", "lua": "lua",
        "php": "php", "dart": "dart", "scala": "scala",
        "zig": "zig", "ex": "elixir", "exs": "elixir",
    ]

    /// Derive a code-fence language hint from a filename's extension.
    /// Returns an empty string for unrecognized extensions (plain code block).
    private static func codeFenceLanguage(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return extensionToLanguage[ext] ?? ""
    }

    // MARK: - System Prompt

    /// Build a system prompt from the assembled context.
    ///
    /// - Parameters:
    ///   - context: The assembled session context with file structure and entity data.
    ///   - sourceApp: The source application name, if known.
    ///   - snippet: The user's selected code snippet, used for framework detection.
    func buildSystemPrompt(context: SessionContext, sourceApp: String?, snippet: String, dsaMode: Bool = false) -> String {
        let lang = Self.codeFenceLanguage(for: context.fileName)

        var prompt = """
            You are Decode, a code explanation tool for macOS. You have deep knowledge \
            of a specific source file. The user selected a code snippet and wants to \
            understand it using the file's structure.

            ## File: \(context.fileName) (\(context.entityCount) entities)

            ### File Structure
            ```
            \(context.fileStructureOutline)
            ```
            """

        // Snippet location (entity-matched case).
        if !context.snippetLocationDescription.isEmpty {
            prompt += "\n\n### Snippet Location\n\(context.snippetLocationDescription)"
        }

        // Containing entity source.
        if let entitySource = context.containingEntitySource {
            prompt += """


                ### Containing Entity Source
                ```\(lang)
                \(entitySource)
                ```
                """
        }

        // Fallback: full file content (small file, no entity match).
        if let fallback = context.fallbackFileContent {
            prompt += """


                ### Full File Content
                ```\(lang)
                \(fallback)
                ```
                """
        }

        // Tier 2.5: surrounding code window.
        if let surrounding = context.surroundingCode,
           let lineRange = context.snippetLineRange {
            prompt += """


                ### Surrounding Code (lines \(lineRange.lowerBound)-\(lineRange.upperBound) and neighbors)
                ```\(lang)
                \(surrounding)
                ```
                """

            // Nearest entities for structural anchoring.
            if let above = context.nearestEntityAbove {
                prompt += "\n\n### Nearest Entity Above\n`\(above.signature)` [lines \(above.startLine)-\(above.endLine)]"
            }
            if let below = context.nearestEntityBelow {
                prompt += "\n\n### Nearest Entity Below\n`\(below.signature)` [lines \(below.startLine)-\(below.endLine)]"
            }
        }

        // Context-tier-specific guidance.
        if context.containingEntitySource != nil {
            prompt += """


                ## Session Context
                - Explain the selected code in the context of its containing entity.
                - Reference other entities in the file structure when they help explain the snippet's role.
                """
        } else if context.fallbackFileContent != nil {
            if context.hasSourceInContext {
                prompt += """


                ## Session Context
                - Focus on the code between the `← SELECTED START` and `← SELECTED END` markers.
                - Use the rest of the file for context, but explain only the selected region.
                - Reference other entities in the file when they help explain the selected code.
                """
            } else {
                prompt += """


                ## Session Context
                - Use your knowledge of the full file to explain the selected snippet.
                - Reference other entities in the file when relevant.
                """
            }
        } else if context.surroundingCode != nil {
            prompt += """


                ## Session Context
                - The snippet was not inside a recognized code entity.
                - Use the surrounding code and file structure to explain what it does.
                - Reference the nearest entities above and below for structural context.
                """
        } else {
            prompt += """


                ## Session Context
                - Use the file structure outline above to provide structural context.
                """
        }

        // Language-specific guidance (non-Swift files only).
        if let langGuide = context.languageGuidance {
            prompt += "\n\n\(langGuide)"
        }

        // Framework-specific explanation structure.
        let framework = ExplanationFramework.select(
            fileName: context.fileName,
            codeSnippet: snippet
        )
        prompt += framework.styleInstructions(dsaMode: dsaMode)

        if let app = sourceApp {
            prompt += "\n\nThe snippet was selected in \(app)."
        }

        return prompt
    }
}

// MARK: - Snippet Location

/// The result of matching a user's selected snippet to a parsed entity.
private struct SnippetLocation {
    /// The most specific entity whose source text contains the snippet.
    let containingEntity: ParsedEntity
}

// ContextBuilderServiceTests.swift — DecodeTests
// Comprehensive unit tests for ContextBuilderService.

import Testing
import Foundation
@testable import Decode

// MARK: - Test Helpers

/// Creates a temp file with given content and returns its path and file metadata.
private func makeTempFile(
    content: String,
    fileName: String = "TestFile.swift"
) -> (path: String, fileId: UUID, fileName: String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fileURL = dir.appendingPathComponent(fileName)
    try! content.write(to: fileURL, atomically: true, encoding: .utf8)

    return (fileURL.path, UUID(), fileName)
}

/// Creates a ParsedEntity for testing.
private func makeEntity(
    sessionId: UUID = UUID(),
    name: String,
    signature: String? = nil,
    sourceText: String,
    startLine: Int,
    endLine: Int,
    parentStableId: String? = nil,
    entityType: EntityType = .function
) -> ParsedEntity {
    let entity = CodeEntity(
        id: UUID(),
        sessionId: sessionId,
        stableId: "\(name)_stable",
        entityType: entityType,
        name: name,
        summaryText: "",
        hash: "hash_\(name)",
        lastUpdated: Date()
    )
    return ParsedEntity(
        entity: entity,
        signature: signature ?? "func \(name)()",
        startLine: startLine,
        endLine: endLine,
        sourceText: sourceText,
        fileName: "TestFile.swift",
        parentStableId: parentStableId
    )
}

// MARK: - Tests

@Suite
struct ContextBuilderServiceTests {

    let service = ContextBuilderService()

    // MARK: - File Cannot Be Read

    @Test func returnsNilWhenFileDoesNotExist() {
        let result = service.buildContext(
            fileId: UUID(),
            filePath: "/nonexistent/path/file.swift",
            fileName: "file.swift",
            parsedEntities: [],
            snippet: "test"
        )
        #expect(result == nil)
    }

    // MARK: - Tier 1: Entity Match

    @Test func tier1EntityMatchReturnsContainingEntitySource() {
        let snippet = "let result = compute(input)"
        let entitySource = "func process() {\n    let result = compute(input)\n    return result\n}"

        let (path, fileId, fileName) = makeTempFile(
            content: "import Foundation\n\n\(entitySource)\n"
        )
        let entity = makeEntity(
            name: "process",
            sourceText: entitySource,
            startLine: 3,
            endLine: 6
        )

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [entity],
            snippet: snippet
        )

        #expect(result != nil)
        #expect(result?.containingEntitySource == entitySource)
        #expect(result?.hasSourceInContext == true)
        #expect(result?.fallbackFileContent == nil)
        #expect(result?.surroundingCode == nil)
    }

    @Test func tier1PicksSmallestMatchingEntity() {
        let snippet = "return x + y"
        let outerSource = "func outer() {\n    func inner() {\n        return x + y\n    }\n}"
        let innerSource = "func inner() {\n    return x + y\n}"

        let (path, fileId, fileName) = makeTempFile(content: outerSource)
        let outer = makeEntity(name: "outer", sourceText: outerSource, startLine: 1, endLine: 5)
        let inner = makeEntity(name: "inner", sourceText: innerSource, startLine: 2, endLine: 4)

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [outer, inner],
            snippet: snippet
        )

        #expect(result != nil)
        // Should pick inner (smaller entity).
        #expect(result?.containingEntitySource == innerSource)
    }

    @Test func tier1NormalizedWhitespaceMatch() {
        let entitySource = "func  test()  {\n    return  42\n}"
        let snippet = "func test() { return 42 }"

        let (path, fileId, fileName) = makeTempFile(content: entitySource)
        let entity = makeEntity(name: "test", sourceText: entitySource, startLine: 1, endLine: 3)

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [entity],
            snippet: snippet
        )

        #expect(result != nil)
        #expect(result?.containingEntitySource == entitySource)
    }

    // MARK: - Tier 2: Small File Fallback

    @Test func tier2SmallFileReturnsFallbackContent() {
        // Build a file under 200 lines with no entity match.
        let content = (1...50).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        let (path, fileId, fileName) = makeTempFile(content: content)

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [],
            snippet: "unmatched snippet that is long enough"
        )

        #expect(result != nil)
        #expect(result?.fallbackFileContent != nil)
        #expect(result?.containingEntitySource == nil)
        #expect(result?.surroundingCode == nil)
    }

    @Test func tier2SmallFileWithSnippetFoundInsertsMarkers() {
        let content = "import Foundation\n\nfunc hello() {\n    print(\"world\")\n}\n"
        let snippet = "print(\"world\")"
        let (path, fileId, fileName) = makeTempFile(content: content)

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [],
            snippet: snippet
        )

        #expect(result != nil)
        #expect(result?.hasSourceInContext == true)
        // Should have selection markers.
        #expect(result?.fallbackFileContent?.contains("← SELECTED START") == true)
        #expect(result?.fallbackFileContent?.contains("← SELECTED END") == true)
    }

    @Test func tier2SmallFileSnippetNotFoundSendsFullFile() {
        let content = "import Foundation\n\nfunc hello() {}\n"
        let (path, fileId, fileName) = makeTempFile(content: content)

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [],
            snippet: "something not in the file at all"
        )

        #expect(result != nil)
        #expect(result?.hasSourceInContext == false)
        #expect(result?.fallbackFileContent == content)
    }

    // MARK: - Tier 2.5: Local Context (Large File)

    @Test func tier25LargeFileSnippetFoundReturnsSurroundingCode() {
        // Build a file over 200 lines.
        var lines = [String]()
        for i in 1...100 { lines.append("let a\(i) = \(i)") }
        lines.append("// TARGET SNIPPET LINE HERE")
        for i in 101...200 { lines.append("let b\(i) = \(i)") }
        let content = lines.joined(separator: "\n")
        let (path, fileId, fileName) = makeTempFile(content: content)

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [],
            snippet: "// TARGET SNIPPET LINE HERE"
        )

        #expect(result != nil)
        #expect(result?.surroundingCode != nil)
        #expect(result?.hasSourceInContext == true)
        #expect(result?.fallbackFileContent == nil)
        #expect(result?.containingEntitySource == nil)
    }

    // MARK: - Tier 3: Large File, No Match

    @Test func tier3LargeFileNoMatchReturnsOutlineOnly() {
        // Build a file over 200 lines.
        let lines = (1...250).map { "let x\($0) = \($0)" }
        let content = lines.joined(separator: "\n")
        let (path, fileId, fileName) = makeTempFile(content: content)

        let entity = makeEntity(
            name: "someFunc",
            sourceText: "func someFunc() { }",
            startLine: 1,
            endLine: 1
        )

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [entity],
            snippet: "completely unrelated text that appears nowhere in file"
        )

        #expect(result != nil)
        #expect(result?.hasSourceInContext == false)
        #expect(result?.fallbackFileContent == nil)
        #expect(result?.surroundingCode == nil)
        #expect(result?.containingEntitySource == nil)
        #expect(!result!.fileStructureOutline.isEmpty)
    }

    // MARK: - Structure Outline

    @Test func outlineContainsEntitySignatures() {
        let content = "struct Foo {\n    func bar() {}\n}\n"
        let (path, fileId, fileName) = makeTempFile(content: content)
        let parent = makeEntity(
            name: "Foo",
            signature: "struct Foo",
            sourceText: content,
            startLine: 1,
            endLine: 3,
            entityType: .struct
        )
        let child = makeEntity(
            name: "bar",
            signature: "func bar()",
            sourceText: "func bar() {}",
            startLine: 2,
            endLine: 2,
            parentStableId: "Foo_stable"
        )

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [parent, child],
            snippet: "unmatched snippet long enough text"
        )

        #expect(result != nil)
        #expect(result?.fileStructureOutline.contains("struct Foo") == true)
        #expect(result?.fileStructureOutline.contains("func bar()") == true)
    }

    @Test func outlineMarksSelectedEntity() {
        let snippet = "func bar() {}"
        let content = "struct Foo {\n    func bar() {}\n    func baz() {}\n}\n"
        let (path, fileId, fileName) = makeTempFile(content: content)
        let parent = makeEntity(
            name: "Foo",
            signature: "struct Foo",
            sourceText: content,
            startLine: 1,
            endLine: 4,
            entityType: .struct
        )
        let child = makeEntity(
            name: "bar",
            signature: "func bar()",
            sourceText: snippet,
            startLine: 2,
            endLine: 2,
            parentStableId: "Foo_stable"
        )

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [parent, child],
            snippet: snippet
        )

        #expect(result != nil)
        #expect(result?.fileStructureOutline.contains("← selected") == true)
    }

    // MARK: - Location Description

    @Test func tier1LocationDescriptionIncludesEntityName() {
        let snippet = "return 42"
        let entitySource = "func compute() -> Int {\n    return 42\n}"
        let content = "\(entitySource)\n"
        let (path, fileId, fileName) = makeTempFile(content: content)
        let entity = makeEntity(
            name: "compute",
            signature: "func compute() -> Int",
            sourceText: entitySource,
            startLine: 1,
            endLine: 3
        )

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [entity],
            snippet: snippet
        )

        #expect(result != nil)
        #expect(result?.snippetLocationDescription.contains("compute") == true)
    }

    // MARK: - Empty Snippet

    @Test func emptySnippetFallsToFileContent() {
        let content = "let x = 1\nlet y = 2\n"
        let (path, fileId, fileName) = makeTempFile(content: content)

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [],
            snippet: ""
        )

        #expect(result != nil)
        // Empty snippet can't match anything → small file fallback.
        #expect(result?.fallbackFileContent != nil)
    }

    // MARK: - Session Context Fields

    @Test func fileIdPreserved() {
        let content = "let x = 1\n"
        let (path, fileId, fileName) = makeTempFile(content: content)

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [],
            snippet: "test"
        )

        #expect(result?.sessionId == fileId)
    }

    @Test func fileNamePreserved() {
        let content = "let x = 1\n"
        let (path, fileId, _) = makeTempFile(content: content, fileName: "MyFile.swift")

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: "MyFile.swift",
            parsedEntities: [],
            snippet: "test"
        )

        #expect(result?.fileName == "MyFile.swift")
    }

    @Test func entityCountReflectsInput() {
        let content = "func a() {}\nfunc b() {}\n"
        let (path, fileId, fileName) = makeTempFile(content: content)
        let e1 = makeEntity(name: "a", sourceText: "func a() {}", startLine: 1, endLine: 1)
        let e2 = makeEntity(name: "b", sourceText: "func b() {}", startLine: 2, endLine: 2)

        let result = service.buildContext(
            fileId: fileId,
            filePath: path,
            fileName: fileName,
            parsedEntities: [e1, e2],
            snippet: "unmatched"
        )

        #expect(result?.entityCount == 2)
    }
}

// MARK: - System Prompt Tests

@Suite
struct ContextBuilderSystemPromptTests {

    let service = ContextBuilderService()

    @Test func systemPromptContainsFileName() {
        let context = SessionContext(
            sessionId: UUID(),
            fileName: "MyService.swift",
            entityCount: 5,
            fileStructureOutline: "struct MyService [lines 1-50]",
            snippetLocationDescription: "",
            containingEntitySource: nil,
            hasSourceInContext: false,
            fallbackFileContent: "let x = 1",
            surroundingCode: nil,
            snippetLineRange: nil,
            nearestEntityAbove: nil,
            nearestEntityBelow: nil,
            languageGuidance: nil
        )

        let prompt = service.buildSystemPrompt(
            context: context,
            sourceApp: nil,
            snippet: "let x = 1"
        )

        #expect(prompt.contains("MyService.swift"))
    }

    @Test func systemPromptContainsOutline() {
        let outline = "struct Foo [lines 1-10]\n  func bar() [lines 2-5]"
        let context = SessionContext(
            sessionId: UUID(),
            fileName: "Test.swift",
            entityCount: 2,
            fileStructureOutline: outline,
            snippetLocationDescription: "",
            containingEntitySource: nil,
            hasSourceInContext: false,
            fallbackFileContent: nil,
            surroundingCode: nil,
            snippetLineRange: nil,
            nearestEntityAbove: nil,
            nearestEntityBelow: nil,
            languageGuidance: nil
        )

        let prompt = service.buildSystemPrompt(
            context: context,
            sourceApp: nil,
            snippet: "test"
        )

        #expect(prompt.contains(outline))
    }

    @Test func systemPromptIncludesSourceApp() {
        let context = SessionContext(
            sessionId: UUID(),
            fileName: "Test.swift",
            entityCount: 0,
            fileStructureOutline: "",
            snippetLocationDescription: "",
            containingEntitySource: nil,
            hasSourceInContext: false,
            fallbackFileContent: nil,
            surroundingCode: nil,
            snippetLineRange: nil,
            nearestEntityAbove: nil,
            nearestEntityBelow: nil,
            languageGuidance: nil
        )

        let prompt = service.buildSystemPrompt(
            context: context,
            sourceApp: "VS Code",
            snippet: "test"
        )

        #expect(prompt.contains("VS Code"))
    }

    @Test func systemPromptIncludesFileIdentity() {
        let context = SessionContext(
            sessionId: UUID(),
            fileName: "Test.swift",
            entityCount: 0,
            fileStructureOutline: "",
            snippetLocationDescription: "",
            containingEntitySource: nil,
            hasSourceInContext: false,
            fallbackFileContent: nil,
            surroundingCode: nil,
            snippetLineRange: nil,
            nearestEntityAbove: nil,
            nearestEntityBelow: nil,
            languageGuidance: nil
        )

        let identity = FileIdentity(
            role: .service,
            layer: .application,
            patterns: [],
            summary: "A networking service that handles API calls"
        )

        let prompt = service.buildSystemPrompt(
            context: context,
            sourceApp: nil,
            snippet: "test",
            fileIdentity: identity
        )

        #expect(prompt.contains("A networking service that handles API calls"))
    }

    @Test func systemPromptIncludesEntitySource() {
        let entitySource = "func process() { return 42 }"
        let context = SessionContext(
            sessionId: UUID(),
            fileName: "Test.swift",
            entityCount: 1,
            fileStructureOutline: "func process() [lines 1-1]",
            snippetLocationDescription: "Inside `process`, a top-level function.",
            containingEntitySource: entitySource,
            hasSourceInContext: true,
            fallbackFileContent: nil,
            surroundingCode: nil,
            snippetLineRange: nil,
            nearestEntityAbove: nil,
            nearestEntityBelow: nil,
            languageGuidance: nil
        )

        let prompt = service.buildSystemPrompt(
            context: context,
            sourceApp: nil,
            snippet: "return 42"
        )

        #expect(prompt.contains("Containing Entity Source"))
        #expect(prompt.contains(entitySource))
    }
}

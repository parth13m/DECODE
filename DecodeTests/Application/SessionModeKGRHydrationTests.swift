// SessionModeKGRHydrationTests.swift — DecodeTests
// Regression tests for KGR artifact hydration into application state.
// Validates: formatSemanticContext, NavigationState sync, and hydration
// through the WorkspaceManager public API.

import Testing
import Foundation
@testable import Decode

// MARK: - formatSemanticContext Tests

@Suite
struct FormatSemanticContextTests {

    @Test @MainActor func nilEnrichment_returnsNil() {
        let result = SessionQuestionCoordinator.formatSemanticContext(nil)
        #expect(result == nil)
    }

    @Test @MainActor func purposeOnly_formatsPurposeSection() {
        let enrichment = SemanticEnrichment(
            purpose: "Manages user authentication state.",
            fileHash: "abc123",
            computedAt: Date()
        )
        let result = SessionQuestionCoordinator.formatSemanticContext(enrichment)
        #expect(result != nil)
        #expect(result!.contains("## File Understanding"))
        #expect(result!.contains("**Purpose:** Manages user authentication state."))
        // No behavior/safety/design sections when nil
        #expect(!result!.contains("**Behavior:**"))
        #expect(!result!.contains("**Safety:**"))
        #expect(!result!.contains("**Design:**"))
    }

    @Test @MainActor func allLayers_formatsAllSections() {
        let enrichment = SemanticEnrichment(
            purpose: "Coordinates workspace lifecycle.",
            behavior: "Stateful — tracks open workspaces in memory.",
            safety: "Thread-confined to MainActor.",
            design: "Uses callback-based decoupling for cross-layer communication.",
            fileHash: "def456",
            computedAt: Date()
        )
        let result = SessionQuestionCoordinator.formatSemanticContext(enrichment)
        #expect(result != nil)
        #expect(result!.contains("**Purpose:** Coordinates workspace lifecycle."))
        #expect(result!.contains("**Behavior:** Stateful"))
        #expect(result!.contains("**Safety:** Thread-confined"))
        #expect(result!.contains("**Design:** Uses callback-based"))
    }

    @Test @MainActor func emptyOptionalLayers_omitted() {
        let enrichment = SemanticEnrichment(
            purpose: "Entry point.",
            behavior: "",
            safety: nil,
            design: "",
            fileHash: "ghi789",
            computedAt: Date()
        )
        let result = SessionQuestionCoordinator.formatSemanticContext(enrichment)
        #expect(result != nil)
        #expect(result!.contains("**Purpose:**"))
        #expect(!result!.contains("**Behavior:**"))
        #expect(!result!.contains("**Safety:**"))
        #expect(!result!.contains("**Design:**"))
    }
}

// MARK: - Workspace Hydration via Public API Tests

@Suite(.serialized)
struct WorkspaceHydrationViaPublicAPITests {

    @Test @MainActor func hydrateSemanticEnrichment_afterFileWorkspaceCreation() async throws {
        let manager = WorkspaceManager()

        // Create a temp Swift file.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode-hydration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("TestHydration.swift")
        try "struct Foo { func bar() { } }".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        try await manager.createFileWorkspace(url: fileURL)

        guard let managed = manager.activeWorkspace else {
            Issue.record("No active workspace after creation")
            return
        }

        // Initially no semantic enrichment.
        #expect(managed.fileIntelligence?.semanticEnrichment == nil)

        let enrichment = SemanticEnrichment(
            purpose: "Test hydration target.",
            behavior: "Stateless utility.",
            fileHash: managed.fileIntelligence?.fileHash ?? "unknown",
            computedAt: Date()
        )

        manager.hydrateSemanticEnrichment(
            workspaceId: managed.id,
            filePath: fileURL.path,
            enrichment: enrichment
        )

        // After hydration, enrichment should be present.
        #expect(managed.fileIntelligence?.semanticEnrichment != nil)
        #expect(managed.fileIntelligence?.semanticEnrichment?.purpose == "Test hydration target.")
        #expect(managed.fileIntelligence?.semanticEnrichment?.behavior == "Stateless utility.")
    }

    @Test @MainActor func hydrateSemanticEnrichment_unknownWorkspace_noOp() {
        let manager = WorkspaceManager()
        let enrichment = SemanticEnrichment(
            purpose: "test",
            fileHash: "abc",
            computedAt: Date()
        )
        // Should not crash — just no-op.
        manager.hydrateSemanticEnrichment(
            workspaceId: UUID(),
            filePath: "/nonexistent",
            enrichment: enrichment
        )
    }
}

// MARK: - NavigationState Sync Tests

@Suite
struct NavigationStateSyncTests {

    @Test @MainActor func selectFile_updatesActiveFilePath() {
        let navState = NavigationState()
        #expect(navState.activeFilePath == nil)

        navState.selectFile(path: "/tmp/project/Sources/Main.swift")
        #expect(navState.activeFilePath == "/tmp/project/Sources/Main.swift")
    }

    @Test @MainActor func selectFile_overwritesPrevious() {
        let navState = NavigationState()
        navState.selectFile(path: "/tmp/project/A.swift")
        navState.selectFile(path: "/tmp/project/B.swift")
        #expect(navState.activeFilePath == "/tmp/project/B.swift")
    }
}

// MARK: - FileUnderstandingJob Decode Tests

@Suite
struct FileUnderstandingJobDecodeTests {

    @Test func decodeEnrichment_validData_returnsEnrichment() {
        let enrichment = SemanticEnrichment(
            purpose: "Manages workspace state.",
            behavior: "Observable, MainActor-confined.",
            safety: "No unsafe concurrency.",
            design: "Composition root pattern.",
            fileHash: "abc123",
            computedAt: Date()
        )
        let data = try! JSONEncoder().encode(enrichment)

        let decoded = FileUnderstandingJob.decodeEnrichment(from: data)
        #expect(decoded != nil)
        #expect(decoded?.purpose == "Manages workspace state.")
        #expect(decoded?.behavior == "Observable, MainActor-confined.")
        #expect(decoded?.safety == "No unsafe concurrency.")
        #expect(decoded?.design == "Composition root pattern.")
    }

    @Test func decodeEnrichment_invalidData_returnsNil() {
        let data = Data("not json".utf8)
        let decoded = FileUnderstandingJob.decodeEnrichment(from: data)
        #expect(decoded == nil)
    }
}

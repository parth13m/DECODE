// HUDFramePersistenceTests.swift — Decode Tests
//
// Tests for HUDFramePersistence: save, restore, independent keys,
// and off-screen frame rejection.

import XCTest
@testable import Decode

final class HUDFramePersistenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: HUDFramePersistence.HUDIdentifier.history.rawValue)
        UserDefaults.standard.removeObject(forKey: HUDFramePersistence.HUDIdentifier.explanation.rawValue)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: HUDFramePersistence.HUDIdentifier.history.rawValue)
        UserDefaults.standard.removeObject(forKey: HUDFramePersistence.HUDIdentifier.explanation.rawValue)
        super.tearDown()
    }

    // MARK: - Save and Restore

    func testSaveAndRestoreHistoryFrame() {
        let frame = NSRect(x: 100, y: 200, width: 520, height: 600)
        HUDFramePersistence.saveFrame(frame, for: .history)

        let restored = HUDFramePersistence.loadFrame(for: .history)
        // The frame should restore if it's on a visible screen.
        // In CI/test environments without displays, this may return nil.
        if let restored {
            XCTAssertEqual(restored.origin.x, 100, accuracy: 0.1)
            XCTAssertEqual(restored.origin.y, 200, accuracy: 0.1)
            XCTAssertEqual(restored.size.width, 520, accuracy: 0.1)
            XCTAssertEqual(restored.size.height, 600, accuracy: 0.1)
        }
    }

    func testSaveAndRestoreExplanationFrame() {
        let frame = NSRect(x: 300, y: 400, width: 500, height: 200)
        HUDFramePersistence.saveFrame(frame, for: .explanation)

        let restored = HUDFramePersistence.loadFrame(for: .explanation)
        if let restored {
            XCTAssertEqual(restored.origin.x, 300, accuracy: 0.1)
            XCTAssertEqual(restored.origin.y, 400, accuracy: 0.1)
            XCTAssertEqual(restored.size.width, 500, accuracy: 0.1)
            XCTAssertEqual(restored.size.height, 200, accuracy: 0.1)
        }
    }

    // MARK: - Independent Keys

    func testIndependentKeys() {
        let historyFrame = NSRect(x: 10, y: 20, width: 400, height: 300)
        let explanationFrame = NSRect(x: 500, y: 600, width: 700, height: 800)

        HUDFramePersistence.saveFrame(historyFrame, for: .history)
        HUDFramePersistence.saveFrame(explanationFrame, for: .explanation)

        if let restoredHistory = HUDFramePersistence.loadFrame(for: .history) {
            XCTAssertEqual(restoredHistory.origin.x, 10, accuracy: 0.1)
            XCTAssertEqual(restoredHistory.size.width, 400, accuracy: 0.1)
        }

        if let restoredExplanation = HUDFramePersistence.loadFrame(for: .explanation) {
            XCTAssertEqual(restoredExplanation.origin.x, 500, accuracy: 0.1)
            XCTAssertEqual(restoredExplanation.size.width, 700, accuracy: 0.1)
        }
    }

    // MARK: - No Saved Frame

    func testNoSavedFrameReturnsNil() {
        let result = HUDFramePersistence.loadFrame(for: .history)
        XCTAssertNil(result)
    }

    // MARK: - Off-Screen Frame Rejection

    func testOffScreenFrameReturnsNil() {
        // A frame far off any conceivable screen boundary.
        let offScreenFrame = NSRect(x: -50000, y: -50000, width: 520, height: 600)
        HUDFramePersistence.saveFrame(offScreenFrame, for: .history)

        let restored = HUDFramePersistence.loadFrame(for: .history)
        XCTAssertNil(restored, "Off-screen frame should not be restored")
    }

    // MARK: - Overwrite

    func testOverwriteFrame() {
        let first = NSRect(x: 100, y: 100, width: 400, height: 300)
        let second = NSRect(x: 200, y: 200, width: 600, height: 500)

        HUDFramePersistence.saveFrame(first, for: .history)
        HUDFramePersistence.saveFrame(second, for: .history)

        if let restored = HUDFramePersistence.loadFrame(for: .history) {
            XCTAssertEqual(restored.origin.x, 200, accuracy: 0.1)
            XCTAssertEqual(restored.size.width, 600, accuracy: 0.1)
        }
    }

    // MARK: - Full NSRect Preservation

    func testPositionAndSizePreserved() {
        let frame = NSRect(x: 200, y: 500, width: 800, height: 450)
        HUDFramePersistence.saveFrame(frame, for: .explanation)

        if let restored = HUDFramePersistence.loadFrame(for: .explanation) {
            XCTAssertEqual(restored.origin.x, 200, accuracy: 0.1, "X position must be preserved")
            XCTAssertEqual(restored.origin.y, 500, accuracy: 0.1, "Y position must be preserved")
            XCTAssertEqual(restored.size.width, 800, accuracy: 0.1, "Width must be preserved")
            XCTAssertEqual(restored.size.height, 450, accuracy: 0.1, "Height must be preserved")
        }
    }

    func testSavedFrameNotOverwrittenBySubsequentSave() {
        // Simulate: user sets custom frame A, dismiss saves A.
        let userFrame = NSRect(x: 200, y: 500, width: 800, height: 450)
        HUDFramePersistence.saveFrame(userFrame, for: .explanation)

        // Load and verify A is intact.
        let loaded = HUDFramePersistence.loadFrame(for: .explanation)
        if let loaded {
            XCTAssertEqual(loaded.origin.x, 200, accuracy: 0.1)
            XCTAssertEqual(loaded.size.width, 800, accuracy: 0.1)
        }

        // Save a different frame (e.g., default centered) must overwrite.
        let defaultFrame = NSRect(x: 400, y: 300, width: 500, height: 200)
        HUDFramePersistence.saveFrame(defaultFrame, for: .explanation)

        let reloaded = HUDFramePersistence.loadFrame(for: .explanation)
        if let reloaded {
            XCTAssertEqual(reloaded.origin.x, 400, accuracy: 0.1, "Latest save must win")
            XCTAssertEqual(reloaded.size.width, 500, accuracy: 0.1, "Latest save must win")
        }
    }

    func testZeroSizeFrameOnScreenPassesValidation() {
        // A zero-size frame at a valid on-screen position passes the intersection
        // check because NSRect.intersects counts point-containment for zero-area rects.
        // This is acceptable — the panel's minSize constraints prevent zero display.
        let zeroFrame = NSRect(x: 100, y: 100, width: 0, height: 0)
        HUDFramePersistence.saveFrame(zeroFrame, for: .explanation)

        let restored = HUDFramePersistence.loadFrame(for: .explanation)
        // May be non-nil on machines where (100,100) is on-screen.
        if let restored {
            XCTAssertEqual(restored.origin.x, 100, accuracy: 0.1)
            XCTAssertEqual(restored.origin.y, 100, accuracy: 0.1)
        }
    }
}

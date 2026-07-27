import Foundation
import Testing
@testable import Decode

/// Tests for ``DirectoryWatcherService`` snapshot building and file filtering (W5).
@Suite(.serialized)
struct DirectoryWatcherServiceTests {

    /// Create a temp directory and return its path with symlinks resolved.
    private func makeTempDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("decode_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var → /private/var symlink on macOS.
        return URL(fileURLWithPath: (base.path as NSString).resolvingSymlinksInPath)
    }

    // MARK: - Snapshot Building

    @Test
    func buildModDateSnapshotReturnsEmptyForNonexistentDirectory() {
        let url = URL(fileURLWithPath: "/tmp/decode_test_nonexistent_\(UUID().uuidString)")
        let snapshot = DirectoryWatcherService.buildModDateSnapshot(rootURL: url)
        #expect(snapshot.isEmpty)
    }

    @Test
    func buildModDateSnapshotFindsSwiftFiles() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let swiftFile = tmpDir.appendingPathComponent("main.swift")
        try "import Foundation".write(to: swiftFile, atomically: true, encoding: .utf8)

        let snapshot = DirectoryWatcherService.buildModDateSnapshot(rootURL: tmpDir)
        #expect(snapshot.count == 1)
        #expect(snapshot.keys.first?.hasSuffix("main.swift") == true)
    }

    @Test
    func buildModDateSnapshotIgnoresUnsupportedExtensions() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let txtFile = tmpDir.appendingPathComponent("readme.txt")
        try "hello".write(to: txtFile, atomically: true, encoding: .utf8)

        let mdFile = tmpDir.appendingPathComponent("notes.md")
        try "# notes".write(to: mdFile, atomically: true, encoding: .utf8)

        let snapshot = DirectoryWatcherService.buildModDateSnapshot(rootURL: tmpDir)
        #expect(snapshot.isEmpty)
    }

    @Test
    func buildModDateSnapshotExcludesNodeModules() throws {
        let tmpDir = try makeTempDir()
        let nodeModules = tmpDir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let jsFile = nodeModules.appendingPathComponent("lib.js")
        try "export default {}".write(to: jsFile, atomically: true, encoding: .utf8)

        let snapshot = DirectoryWatcherService.buildModDateSnapshot(rootURL: tmpDir)
        #expect(snapshot.isEmpty)
    }

    @Test
    func buildModDateSnapshotExcludesBuildDirectory() throws {
        let tmpDir = try makeTempDir()
        let buildDir = tmpDir.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let swiftFile = buildDir.appendingPathComponent("generated.swift")
        try "// generated".write(to: swiftFile, atomically: true, encoding: .utf8)

        let snapshot = DirectoryWatcherService.buildModDateSnapshot(rootURL: tmpDir)
        #expect(snapshot.isEmpty)
    }

    @Test
    func buildModDateSnapshotFindsMultipleLanguages() throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "print(1)".write(to: tmpDir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        try "print(1)".write(to: tmpDir.appendingPathComponent("script.py"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: tmpDir.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)

        let snapshot = DirectoryWatcherService.buildModDateSnapshot(rootURL: tmpDir)
        #expect(snapshot.count == 3)
    }

    @Test
    func buildModDateSnapshotRecursesSubdirectories() throws {
        let tmpDir = try makeTempDir()
        let subDir = tmpDir.appendingPathComponent("Sources/Core")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "// swift-tools-version: 5.9".write(to: tmpDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "struct App {}".write(to: subDir.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)

        let snapshot = DirectoryWatcherService.buildModDateSnapshot(rootURL: tmpDir)
        #expect(snapshot.count == 2)
        let filenames = Set(snapshot.keys.map { ($0 as NSString).lastPathComponent })
        #expect(filenames.contains("Package.swift"))
        #expect(filenames.contains("App.swift"))
    }

    // MARK: - Watcher Lifecycle

    @Test
    func stopWatchingBeforeStartDoesNotCrash() {
        let watcher = DirectoryWatcherService()
        watcher.stopWatching()
    }

    @Test
    func startWatchingWithInvalidPathFinishesStream() async {
        let watcher = DirectoryWatcherService()
        let stream = watcher.startWatching(
            directoryURL: URL(fileURLWithPath: "/nonexistent_\(UUID().uuidString)")
        )
        var events: [[FileChangeEvent]] = []
        for await batch in stream {
            events.append(batch)
        }
        #expect(events.isEmpty)
    }
}

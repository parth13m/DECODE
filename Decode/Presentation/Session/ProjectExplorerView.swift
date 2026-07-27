import SwiftUI

/// Tree view of files in a `.directory` workspace.
///
/// Displays the file hierarchy grouped by subdirectory. Selecting a file
/// updates the ``NavigationState`` to show that file's intelligence in the
/// center column of the Knowledge Inspector.
struct ProjectExplorerView: View {

    let rootPath: String
    let filePaths: [String]
    let activeFilePath: String?
    let onSelectFile: (String) -> Void

    // MARK: - WhisperFlow palette

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let tree = Self.buildTree(rootPath: rootPath, filePaths: filePaths)
                ForEach(tree) { node in
                    fileTreeRow(node: node, depth: 0)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Row Rendering

    @ViewBuilder
    private func fileTreeRow(node: FileTreeNode, depth: Int) -> some View {
        if node.isDirectory {
            directoryRow(node: node, depth: depth)
        } else {
            fileRow(node: node, depth: depth)
        }
    }

    private func directoryRow(node: FileTreeNode, depth: Int) -> some View {
        DisclosureGroup {
            ForEach(node.children) { child in
                fileTreeRow(node: child, depth: depth + 1)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(accentOrange.opacity(0.7))
                Text(node.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(node.fileCount)")
                    .font(.system(size: 10))
                    .foregroundStyle(textSecondary)
            }
            .padding(.leading, CGFloat(depth) * 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private func fileRow(node: FileTreeNode, depth: Int) -> some View {
        let isActive = node.fullPath == activeFilePath
        return Button {
            if let path = node.fullPath {
                onSelectFile(path)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.iconForExtension(node.name))
                    .font(.system(size: 11))
                    .foregroundStyle(isActive ? accentOrange : textSecondary)
                Text(node.name)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? accentOrange : textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 16)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(isActive ? accentOrange.opacity(0.08) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - File Icon

    private static func iconForExtension(_ fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "js", "jsx", "mjs", "cjs": return "doc.text"
        case "ts", "tsx": return "doc.text"
        case "html", "htm": return "globe"
        case "css", "scss": return "paintpalette"
        case "java": return "cup.and.saucer"
        case "c", "cpp", "h", "hpp", "cxx", "cc", "hxx": return "doc.text"
        case "cs": return "doc.text"
        default: return "doc"
        }
    }

    // MARK: - Tree Building

    /// Build a hierarchical tree from flat file paths.
    static func buildTree(rootPath: String, filePaths: [String]) -> [FileTreeNode] {
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        // Group files by their relative directory.
        var dirChildren: [String: [FileTreeNode]] = [:]

        for path in filePaths.sorted() {
            let relativePath: String
            if path.hasPrefix(rootPrefix) {
                relativePath = String(path.dropFirst(rootPrefix.count))
            } else {
                relativePath = (path as NSString).lastPathComponent
            }

            let components = relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }

            if components.count == 1 {
                // Top-level file.
                let node = FileTreeNode(
                    name: components[0],
                    isDirectory: false,
                    fullPath: path,
                    children: []
                )
                dirChildren["", default: []].append(node)
            } else {
                // File in a subdirectory — group by first directory component.
                let dirName = components[0]
                let node = FileTreeNode(
                    name: components.dropFirst().joined(separator: "/"),
                    isDirectory: false,
                    fullPath: path,
                    children: []
                )
                dirChildren[dirName, default: []].append(node)
            }
        }

        var result: [FileTreeNode] = []

        // Build directory nodes.
        for dirName in dirChildren.keys.sorted() where !dirName.isEmpty {
            let children = dirChildren[dirName] ?? []
            // Recursively structure nested paths.
            let subTree = buildSubTree(children: children)
            let dirNode = FileTreeNode(
                name: dirName,
                isDirectory: true,
                fullPath: nil,
                children: subTree
            )
            result.append(dirNode)
        }

        // Top-level files.
        if let topFiles = dirChildren[""] {
            result.append(contentsOf: topFiles)
        }

        return result
    }

    /// Recursively build sub-trees from relative paths that may contain
    /// further directory separators.
    private static func buildSubTree(children: [FileTreeNode]) -> [FileTreeNode] {
        var dirChildren: [String: [FileTreeNode]] = [:]
        var fileNodes: [FileTreeNode] = []

        for child in children {
            let components = child.name.split(separator: "/").map(String.init)
            if components.count == 1 {
                fileNodes.append(FileTreeNode(
                    name: components[0],
                    isDirectory: false,
                    fullPath: child.fullPath,
                    children: []
                ))
            } else {
                let dirName = components[0]
                let subNode = FileTreeNode(
                    name: components.dropFirst().joined(separator: "/"),
                    isDirectory: false,
                    fullPath: child.fullPath,
                    children: []
                )
                dirChildren[dirName, default: []].append(subNode)
            }
        }

        var result: [FileTreeNode] = []
        for dirName in dirChildren.keys.sorted() {
            let subChildren = dirChildren[dirName] ?? []
            let subTree = buildSubTree(children: subChildren)
            result.append(FileTreeNode(
                name: dirName,
                isDirectory: true,
                fullPath: nil,
                children: subTree
            ))
        }
        result.append(contentsOf: fileNodes.sorted { $0.name < $1.name })
        return result
    }
}

// MARK: - FileTreeNode

/// A node in the project file tree — either a directory or a file.
struct FileTreeNode: Identifiable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let fullPath: String?
    let children: [FileTreeNode]

    /// Total file count (recursively) for display in directory labels.
    var fileCount: Int {
        if !isDirectory { return 1 }
        return children.reduce(0) { $0 + $1.fileCount }
    }
}

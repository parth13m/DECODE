import SwiftUI

/// Knowledge Inspector — Decode's brain, exposed.
///
/// Three-column layout:
/// 1. Workspace list sidebar (left) — all open workspaces with active indicator
/// 2. Knowledge content (center) — scrollable sections showing everything Decode knows
/// 3. Entity detail panel (right) — metadata for the selected entity
struct SessionView: View {

    @Bindable var viewModel: SessionViewModel

    /// Tracks which parent entities are expanded in the entity tree.
    @State private var collapsedParents: Set<String> = []

    /// Tracks which knowledge sections are collapsed.
    @State private var collapsedSections: Set<String> = []

    // MARK: - WhisperFlow-inspired palette (matches ContentView/HUD)

    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)
    private let subtleGreen = Color(red: 0.30, green: 0.69, blue: 0.31)
    private let subtleBlue = Color(red: 0.30, green: 0.50, blue: 0.70)

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(cardBorder)
            contentArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(warmBackground)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentOrange)

            Text(viewModel.fileName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textPrimary)
                .lineLimit(1)

            if viewModel.isDirectoryWorkspace {
                if let state = viewModel.indexingState, state.isActive {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(accentOrange)
                        if let fraction = state.progressFraction {
                            Text("Indexing \(Int(fraction * 100))%")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(accentOrange)
                        } else {
                            Text("Scanning...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(accentOrange)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(accentOrange.opacity(0.7))
                        Text("\(viewModel.discoveredFiles.count) files")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(textSecondary)
                    }
                }
            } else if viewModel.isWatching {
                HStack(spacing: 4) {
                    Circle()
                        .fill(subtleGreen)
                        .frame(width: 7, height: 7)
                    Text("Watching")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
            }

            Spacer()

            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentOrange)
            }

            Text("\(viewModel.allWorkspaces.count) session\(viewModel.allWorkspaces.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textSecondary)

            Button {
                viewModel.openFile()
            } label: {
                Label("Open File", systemImage: "doc")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(accentOrange)

            Button {
                viewModel.openDirectory()
            } label: {
                Label("Open Folder", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(accentOrange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if let error = viewModel.errorMessage {
            errorView(error)
        } else if viewModel.allWorkspaces.isEmpty && viewModel.activeWorkspace == nil {
            emptyState
        } else {
            mainContent
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        HSplitView {
            if viewModel.isDirectoryWorkspace {
                // Directory workspace: 3-pane IDE-like layout
                projectExplorerPanel
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 320)

                contextualContentPanel
                    .frame(minWidth: 320, idealWidth: 480)

                detailPanel
                    .frame(minWidth: 280, idealWidth: 380)
            } else {
                // Single-file workspace: 3-pane with sessions list
                sessionListPanel
                    .frame(minWidth: 150, idealWidth: 180, maxWidth: 240)

                knowledgeContentPanel
                    .frame(minWidth: 320, idealWidth: 440)

                detailPanel
                    .frame(minWidth: 280, idealWidth: 380)
            }
        }
    }

    // MARK: - Project Explorer (Directory Workspaces)

    @ViewBuilder
    private var projectExplorerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Workspace switcher (compact)
            if viewModel.allWorkspaces.count > 1 {
                workspaceSwitcher
                Divider().overlay(cardBorder)
            }

            // Project explorer header
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(accentOrange)
                Text("Explorer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(textSecondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(cardBorder)

            if let workspace = viewModel.activeWorkspace {
                ProjectExplorerView(
                    rootPath: workspace.workspace.rootPath,
                    rootName: viewModel.rootName,
                    filePaths: viewModel.discoveredFiles,
                    activeFilePath: viewModel.navigationState.activeFilePath,
                    selectedFolderPath: viewModel.navigationState.selectedFolderPath,
                    expandedFolders: viewModel.navigationState.expandedFolders,
                    onSelectFile: { path in
                        viewModel.navigationState.selectFile(path: path)
                    },
                    onSelectFolder: { relativePath in
                        viewModel.navigationState.selectFolder(relativePath: relativePath)
                    },
                    onToggleFolder: { relativePath in
                        viewModel.navigationState.toggleFolderExpansion(relativePath: relativePath)
                    }
                )
            }
        }
        .background(warmBackground.opacity(0.95))
    }

    // MARK: - Workspace Switcher (compact, for multi-workspace)

    private var workspaceSwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(viewModel.allWorkspaces) { managed in
                    let isActive = viewModel.activeWorkspaceId == managed.workspace.id

                    Button {
                        viewModel.switchToWorkspace(id: managed.workspace.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: managed.workspace.kind == .directory ? "folder.fill" : "doc.fill")
                                .font(.system(size: 9))
                            Text(managed.workspace.rootFileName)
                                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(isActive ? accentOrange : textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isActive ? accentOrange.opacity(0.1) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Contextual Content Panel (Pane 2)

    @ViewBuilder
    private var contextualContentPanel: some View {
        if viewModel.navigationState.selectedFolderPath != nil {
            folderContentsPanel
        } else if viewModel.navigationState.activeFilePath != nil {
            knowledgeContentPanel
        } else {
            // No selection — prompt user
            VStack(spacing: 12) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(textSecondary.opacity(0.4))
                Text("Select a file or folder in the explorer")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(warmBackground)
        }
    }

    // MARK: - Folder Contents Panel

    private var folderContentsPanel: some View {
        let relativePath = viewModel.navigationState.selectedFolderPath ?? ""
        let folderName = relativePath.isEmpty
            ? viewModel.rootName
            : (relativePath as NSString).lastPathComponent
        let contents = viewModel.folderContents(relativePath: relativePath)

        return VStack(alignment: .leading, spacing: 0) {
            // Breadcrumb header
            folderBreadcrumb(relativePath: relativePath)

            Divider().overlay(cardBorder)

            if contents.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(textSecondary.opacity(0.4))
                    Text("This folder has no indexed files")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Folders first
                        ForEach(contents.folders) { item in
                            folderContentRow(item: item)
                            Divider().overlay(cardBorder.opacity(0.3)).padding(.leading, 40)
                        }

                        // Then files
                        ForEach(contents.files) { item in
                            fileContentRow(item: item)
                            Divider().overlay(cardBorder.opacity(0.3)).padding(.leading, 40)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(warmBackground)
    }

    // MARK: - Folder Breadcrumb

    private func folderBreadcrumb(relativePath: String) -> some View {
        let components: [String]
        if relativePath.isEmpty {
            components = [viewModel.rootName]
        } else {
            components = [viewModel.rootName] + relativePath.split(separator: "/").map(String.init)
        }

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(components.enumerated()), id: \.offset) { index, component in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(textSecondary.opacity(0.5))
                    }

                    let targetPath: String = {
                        if index == 0 { return "" }
                        let pathComponents = relativePath.split(separator: "/").map(String.init)
                        return pathComponents.prefix(index).joined(separator: "/")
                    }()

                    let isLast = index == components.count - 1

                    Button {
                        viewModel.navigationState.selectFolder(relativePath: targetPath)
                    } label: {
                        HStack(spacing: 3) {
                            if index == 0 {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(accentOrange.opacity(0.7))
                            }
                            Text(component)
                                .font(.system(size: 12, weight: isLast ? .semibold : .medium))
                                .foregroundStyle(isLast ? textPrimary : accentOrange)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLast)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Folder/File Content Rows

    private func folderContentRow(item: FolderContents.Item) -> some View {
        Button {
            if let rp = item.relativePath {
                viewModel.navigationState.selectFolder(relativePath: rp)
                // Also expand in tree
                if !viewModel.navigationState.expandedFolders.contains(rp) {
                    viewModel.navigationState.toggleFolderExpansion(relativePath: rp)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(accentOrange.opacity(0.7))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(textPrimary)
                        .lineLimit(1)
                    Text("\(item.fileCount) file\(item.fileCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(textSecondary.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Folder: \(item.name), \(item.fileCount) files")
    }

    private func fileContentRow(item: FolderContents.Item) -> some View {
        let isActive = item.fullPath == viewModel.navigationState.activeFilePath

        return Button {
            if let path = item.fullPath {
                viewModel.navigationState.selectFile(path: path)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: ProjectExplorerView.iconForExtension(item.name))
                    .font(.system(size: 14))
                    .foregroundStyle(isActive ? accentOrange : textSecondary)
                    .frame(width: 24)

                Text(item.name)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? accentOrange : textPrimary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isActive ? accentOrange.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("File: \(item.name)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Knowledge Content (Center Column)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var knowledgeContentPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {

                // ─── WHAT DECODE SEES ───
                groupHeader("What Decode Sees", icon: "eye")

                fileOverviewSection
                structureSection
                entitiesSection
                importsSection
                relationshipsSection

                // ─── WHAT DECODE UNDERSTANDS ───
                groupHeader("What Decode Understands", icon: "lightbulb")

                identitySection
                purposeSection
                behaviorSection
                safetySection
                designSection

                // ─── HOW DECODE REASONS ───
                if viewModel.lastQuestionContext != nil {
                    groupHeader("How Decode Reasons", icon: "gearshape.2")
                    questionContextSection
                }

                // ─── FUTURE ───
                groupHeader("Coming Soon", icon: "sparkles")
                futurePlaceholderSection("Module Intelligence", description: "Cross-file relationships and module-level context")
                futurePlaceholderSection("Project Intelligence", description: "Whole-codebase architecture understanding")

                // ─── META ───
                groupHeader("Timeline", icon: "clock")
                timelineSection

                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 16)
        }
        .background(warmBackground)
    }

    // MARK: - Group Header

    private func groupHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accentOrange)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accentOrange)
                .textCase(.uppercase)
                .tracking(1.2)
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Collapsible Section

    @ViewBuilder
    private func collapsibleSection(
        _ id: String,
        title: String,
        count: Int? = nil,
        icon: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        let isCollapsed = collapsedSections.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 6) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(textSecondary)
                    .frame(width: 10)

                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(textSecondary)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(textPrimary)

                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(textSecondary.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(cardBorder))
                }

                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isCollapsed {
                        collapsedSections.remove(id)
                    } else {
                        collapsedSections.insert(id)
                    }
                }
            }

            if !isCollapsed {
                content()
                    .padding(.leading, 16)
                    .padding(.bottom, 8)
            }

            Divider().overlay(cardBorder.opacity(0.5))
        }
    }

    // MARK: - "Not Generated" Indicator

    private func notGeneratedPill(_ message: String = "Ask a question about this file to generate") -> some View {
        HStack(spacing: 6) {
            Circle()
                .stroke(textSecondary.opacity(0.3), lineWidth: 1.5)
                .frame(width: 8, height: 8)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textSecondary.opacity(0.6))
                .italic()
        }
        .padding(.vertical, 4)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - WHAT DECODE SEES
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // MARK: File Overview

    @ViewBuilder
    private var fileOverviewSection: some View {
        collapsibleSection("fileOverview", title: "File Overview", icon: "doc.text") {
            if let intel = viewModel.intelligence, let workspace = viewModel.activeWorkspace {
                VStack(alignment: .leading, spacing: 6) {
                    metadataRow("File", intel.fileName)
                    metadataRow("Language", intel.language.capitalized)
                    metadataRow("Lines", "\(intel.lineCount)")
                    metadataRow("Hash", String(intel.fileHash.prefix(12)))
                    metadataRow("Built", formatRelativeDate(intel.buildDate))
                    if !workspace.isFileAccessible {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.red.opacity(0.7))
                            Text("File not accessible")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red.opacity(0.7))
                        }
                    }
                }
            }
        }
    }

    // MARK: Structure

    @ViewBuilder
    private var structureSection: some View {
        if let outline = viewModel.structureOutline {
            collapsibleSection("structure", title: "Structure", icon: "list.bullet.indent") {
                Text(outline)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(codeBlockBackground)
            }
        }
    }

    // MARK: Entities

    @ViewBuilder
    private var entitiesSection: some View {
        let entities = viewModel.parsedEntities
        if !entities.isEmpty {
            collapsibleSection("entities", title: "Entities", count: entities.count, icon: "cube") {
                let hierarchy = buildHierarchy()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hierarchy, id: \.parent.id) { group in
                        parentRow(group.parent, childCount: group.children.count)
                            .onTapGesture {
                                viewModel.selectedEntityID = group.parent.id
                            }

                        if !collapsedParents.contains(group.parent.entity.stableId) {
                            ForEach(group.children) { child in
                                childRow(child)
                                    .onTapGesture {
                                        viewModel.selectedEntityID = child.id
                                    }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Imports

    @ViewBuilder
    private var importsSection: some View {
        let imports = viewModel.imports
        if !imports.isEmpty {
            let grouped = Dictionary(grouping: imports, by: \.moduleName)
            let sortedModules = grouped.keys.sorted()

            collapsibleSection("imports", title: "Imports", count: sortedModules.count, icon: "shippingbox") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedModules, id: \.self) { module in
                        let moduleImports = grouped[module] ?? []
                        HStack(spacing: 6) {
                            importKindBadge(moduleImports.first?.kind ?? .module)
                            Text(module)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(textPrimary)

                            let symbols = moduleImports.flatMap(\.importedSymbols)
                            if !symbols.isEmpty {
                                Text("(\(symbols.joined(separator: ", ")))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if let line = moduleImports.first?.line {
                                Text("L\(line)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(textSecondary.opacity(0.5))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: Relationships

    @ViewBuilder
    private var relationshipsSection: some View {
        let rels = viewModel.relationships
        if !rels.isEmpty {
            collapsibleSection("relationships", title: "Relationships", count: rels.count, icon: "arrow.triangle.branch") {
                let entityNames = Set(viewModel.parsedEntities.map(\.entity.name))
                let entities = viewModel.parsedEntities

                let calls = rels.filter { $0.kind == .calls }
                let conformances = rels.filter { $0.kind == .conformsTo }
                let inheritances = rels.filter { $0.kind == .inherits }
                let ownerships = rels.filter { $0.kind == .owns }

                // Entry Points
                let entryPoints = viewModel.entryPoints
                if !entryPoints.isEmpty {
                    relationshipSubHeader("Entry Points", count: entryPoints.count, icon: "arrow.right.circle")
                    ForEach(entryPoints, id: \.id) { entity in
                        HStack(spacing: 6) {
                            entityTypeIcon(entity.entity.entityType)
                            Text(entity.entity.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(accentOrange)
                        }
                        .padding(.vertical, 1)
                        .onTapGesture { viewModel.selectedEntityID = entity.id }
                    }
                    Spacer().frame(height: 8)
                }

                // Calls (internal)
                let internalCalls = calls.filter { entityNames.contains($0.targetName) }
                if !internalCalls.isEmpty {
                    relationshipSubHeader("Internal Calls", count: internalCalls.count, icon: "arrow.right")
                    ForEach(Array(internalCalls.enumerated()), id: \.offset) { _, rel in
                        relationshipEdge(rel, entities: entities)
                    }
                    Spacer().frame(height: 8)
                }

                // External Calls
                let externalCalls = viewModel.externalCalls
                if !externalCalls.isEmpty {
                    relationshipSubHeader("External Calls", count: externalCalls.count, icon: "arrow.up.right")
                    FlowLayout(spacing: 6) {
                        ForEach(externalCalls, id: \.self) { name in
                            Text(name)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(subtleBlue)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(subtleBlue.opacity(0.08), in: Capsule())
                        }
                    }
                    Spacer().frame(height: 8)
                }

                // Conformance
                if !conformances.isEmpty {
                    relationshipSubHeader("Conformance", count: conformances.count, icon: "checkmark.seal")
                    ForEach(Array(conformances.enumerated()), id: \.offset) { _, rel in
                        relationshipEdge(rel, entities: entities)
                    }
                    Spacer().frame(height: 8)
                }

                // Inheritance
                if !inheritances.isEmpty {
                    relationshipSubHeader("Inheritance", count: inheritances.count, icon: "arrow.up")
                    ForEach(Array(inheritances.enumerated()), id: \.offset) { _, rel in
                        relationshipEdge(rel, entities: entities)
                    }
                    Spacer().frame(height: 8)
                }

                // Ownership
                if !ownerships.isEmpty {
                    relationshipSubHeader("Ownership", count: ownerships.count, icon: "rectangle.on.rectangle")
                    ForEach(Array(ownerships.prefix(15).enumerated()), id: \.offset) { _, rel in
                        relationshipEdge(rel, entities: entities)
                    }
                    if ownerships.count > 15 {
                        Text("+ \(ownerships.count - 15) more")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(textSecondary.opacity(0.6))
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - WHAT DECODE UNDERSTANDS
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // MARK: Identity

    @ViewBuilder
    private var identitySection: some View {
        collapsibleSection("identity", title: "Identity", icon: "person.text.rectangle") {
            if let identity = viewModel.identity {
                VStack(alignment: .leading, spacing: 8) {
                    // Role and Layer pills
                    HStack(spacing: 8) {
                        pill(identity.role.label, color: accentOrange)
                        pill(identity.layer.label, color: subtleBlue)
                    }

                    // Detected patterns
                    if !identity.patterns.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(identity.patterns, id: \.self) { pattern in
                                pill(pattern, color: textSecondary)
                            }
                        }
                    }

                    // Summary
                    Text(identity.summary)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                notGeneratedPill("Open a file to see identity analysis")
            }
        }
    }

    // MARK: Purpose

    @ViewBuilder
    private var purposeSection: some View {
        collapsibleSection("purpose", title: "Purpose", icon: "target") {
            VStack(alignment: .leading, spacing: 8) {
                // Deterministic purpose — always available
                if let purpose = viewModel.deterministicPurpose {
                    understandingLayer("Deterministic", text: purpose, available: true)
                }

                // Semantic purpose — only after enrichment
                if let enrichment = viewModel.enrichment {
                    understandingLayer("Semantic", text: enrichment.purpose, available: true)
                } else {
                    understandingLayer("Semantic", text: nil, available: false)
                }
            }
        }
    }

    // MARK: Behavior

    @ViewBuilder
    private var behaviorSection: some View {
        collapsibleSection("behavior", title: "Behavior", icon: "waveform.path.ecg") {
            if let behavior = viewModel.enrichment?.behavior {
                understandingLayer(nil, text: behavior, available: true)
            } else {
                notGeneratedPill()
            }
        }
    }

    // MARK: Safety

    @ViewBuilder
    private var safetySection: some View {
        collapsibleSection("safety", title: "Safety", icon: "shield") {
            if let safety = viewModel.enrichment?.safety {
                understandingLayer(nil, text: safety, available: true)
            } else {
                notGeneratedPill()
            }
        }
    }

    // MARK: Design

    @ViewBuilder
    private var designSection: some View {
        collapsibleSection("design", title: "Design", icon: "square.on.square.intersection.dashed") {
            if let design = viewModel.enrichment?.design {
                understandingLayer(nil, text: design, available: true)
            } else {
                notGeneratedPill()
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - HOW DECODE REASONS
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @ViewBuilder
    private var questionContextSection: some View {
        if let ctx = viewModel.lastQuestionContext {
            collapsibleSection("questionContext", title: "Last Question", icon: "questionmark.bubble") {
                VStack(alignment: .leading, spacing: 6) {
                    metadataRow("Context Tier", ctx.contextTier)
                    metadataRow("Health", "\(ctx.healthTier)\(ctx.healthHintCount > 0 ? " (\(ctx.healthHintCount) hints)" : "")")
                    metadataRow("Prompt Size", "~\(formatNumber(ctx.promptCharacterCount)) chars")
                    metadataRow("Cache", ctx.enrichmentCacheHit ? "Hit" : "Miss")

                    // Layer selection
                    HStack(spacing: 6) {
                        Text("Layers")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(textSecondary)
                            .frame(width: 80, alignment: .trailing)
                        layerDot("Purpose", active: true)
                        layerDot("Behavior", active: ctx.includedBehavior)
                        layerDot("Safety", active: ctx.includedSafety)
                        layerDot("Design", active: ctx.includedDesign)
                    }

                    metadataRow("Asked", formatRelativeDate(ctx.timestamp))
                }
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - FUTURE & TIMELINE
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func futurePlaceholderSection(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(textSecondary.opacity(0.4))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(textSecondary.opacity(0.5))
                Spacer()
            }
            .padding(.vertical, 8)

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(textSecondary.opacity(0.4))
                .italic()
                .padding(.leading, 16)
                .padding(.bottom, 8)

            Divider().overlay(cardBorder.opacity(0.3))
        }
    }

    @ViewBuilder
    private var timelineSection: some View {
        collapsibleSection("timeline", title: "Events", icon: "list.bullet.rectangle") {
            if let workspace = viewModel.activeWorkspace {
                VStack(alignment: .leading, spacing: 4) {
                    timelineEvent("File opened", date: workspace.workspace.createdAt)
                    if let intel = viewModel.intelligence {
                        timelineEvent("Parsed & analyzed", date: intel.buildDate)
                    }
                    if let enrichment = viewModel.enrichment {
                        timelineEvent("Semantic enrichment generated", date: enrichment.computedAt)
                    }
                    if let refreshed = workspace.lastRefreshedAt {
                        timelineEvent("Last refreshed", date: refreshed)
                    }
                    if let ctx = viewModel.lastQuestionContext {
                        timelineEvent("Last question answered", date: ctx.timestamp)
                    }
                }
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Workspace List Panel (left column)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var sessionListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(textSecondary)
                    .textCase(.uppercase)
                Spacer()
                Menu {
                    Button {
                        viewModel.openFile()
                    } label: {
                        Label("Open File", systemImage: "doc")
                    }
                    Button {
                        viewModel.openDirectory()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accentOrange)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add Session")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(warmBackground)

            Divider().overlay(cardBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.allWorkspaces) { managed in
                        workspaceRow(managed)
                        Divider().overlay(cardBorder.opacity(0.5))
                    }
                }
            }
        }
        .background(warmBackground)
    }

    private func workspaceRow(_ managed: ManagedWorkspace) -> some View {
        let isActive = viewModel.activeWorkspaceId == managed.workspace.id

        return HStack(spacing: 8) {
            Circle()
                .fill(isActive ? subtleGreen : Color.clear)
                .overlay(
                    Circle()
                        .stroke(isActive ? Color.clear : cardBorder, lineWidth: 1)
                )
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(managed.workspace.rootFileName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? textPrimary : textSecondary)
                    .lineLimit(1)

                Text("\(managed.parsedEntities.count) entities")
                    .font(.system(size: 10))
                    .foregroundStyle(textSecondary.opacity(0.7))
            }

            Spacer()

            Button {
                viewModel.closeWorkspace(id: managed.workspace.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(textSecondary.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isActive ? accentOrange.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.switchToWorkspace(id: managed.workspace.id)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Detail Panel (right column — reused)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    @ViewBuilder
    private var detailPanel: some View {
        if let selected = viewModel.selectedEntity {
            let parentName = resolveParentName(for: selected)
            let childEntities = resolveChildren(for: selected)
            EntityDetailView(
                parsed: selected,
                parentName: parentName,
                children: childEntities,
                accentOrange: accentOrange,
                cardBorder: cardBorder,
                textPrimary: textPrimary,
                textSecondary: textSecondary,
                warmBackground: warmBackground
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(textSecondary.opacity(0.4))
                Text("Select an entity to inspect")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(warmBackground.opacity(0.5))
        }
    }

    private func resolveParentName(for entity: ParsedEntity) -> String? {
        guard let pid = entity.parentStableId else { return nil }
        return viewModel.parsedEntities.first { $0.entity.stableId == pid }?.entity.name
    }

    private func resolveChildren(for entity: ParsedEntity) -> [ParsedEntity] {
        guard entity.isTopLevel else { return [] }
        return viewModel.parsedEntities.filter { $0.parentStableId == entity.entity.stableId }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Reusable Components
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // MARK: Entity Hierarchy (reused from original)

    private func buildHierarchy() -> [EntityGroup] {
        let entities = viewModel.parsedEntities
        let topLevel = entities.filter { $0.isTopLevel }
        let children = entities.filter { !$0.isTopLevel }

        var childrenByParent: [String: [ParsedEntity]] = [:]
        for child in children {
            if let pid = child.parentStableId {
                childrenByParent[pid, default: []].append(child)
            }
        }

        var groups: [EntityGroup] = []
        for parent in topLevel {
            let kids = childrenByParent[parent.entity.stableId] ?? []
            groups.append(EntityGroup(parent: parent, children: kids))
        }

        let knownParents = Set(topLevel.map(\.entity.stableId))
        let orphans = children.filter {
            guard let pid = $0.parentStableId else { return false }
            return !knownParents.contains(pid)
        }
        for orphan in orphans {
            groups.append(EntityGroup(parent: orphan, children: []))
        }

        return groups
    }

    private func parentRow(_ parsed: ParsedEntity, childCount: Int) -> some View {
        let isSelected = viewModel.selectedEntityID == parsed.id
        let isCollapsed = collapsedParents.contains(parsed.entity.stableId)

        return HStack(spacing: 6) {
            if childCount > 0 {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(textSecondary)
                    .frame(width: 12)
                    .onTapGesture {
                        if isCollapsed {
                            collapsedParents.remove(parsed.entity.stableId)
                        } else {
                            collapsedParents.insert(parsed.entity.stableId)
                        }
                    }
            } else {
                Spacer().frame(width: 12)
            }

            entityTypeIcon(parsed.entity.entityType)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(parsed.entity.name)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(textPrimary)

                    if childCount > 0 {
                        Text("\(childCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(textSecondary.opacity(0.7))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(cardBorder))
                    }
                }

                Text(parsed.lineRangeDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(textSecondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .background(isSelected ? accentOrange.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }

    private func childRow(_ parsed: ParsedEntity) -> some View {
        let isSelected = viewModel.selectedEntityID == parsed.id
        let shortName: String = {
            if let dotIndex = parsed.entity.name.lastIndex(of: ".") {
                return String(parsed.entity.name[parsed.entity.name.index(after: dotIndex)...])
            }
            return parsed.entity.name
        }()

        return HStack(spacing: 6) {
            Spacer().frame(width: 12)
            entityTypeIcon(parsed.entity.entityType)

            Text(shortName)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(textPrimary)

            Spacer()

            Text(parsed.lineRangeDescription)
                .font(.system(size: 10))
                .foregroundStyle(textSecondary.opacity(0.6))
        }
        .padding(.leading, 20)
        .padding(.vertical, 3)
        .background(isSelected ? accentOrange.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: Entity Type Icons (reused)

    private func entityTypeIcon(_ type: EntityType) -> some View {
        let (icon, color) = iconForType(type)
        return Text(icon)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(color, in: RoundedRectangle(cornerRadius: 5))
    }

    private func iconForType(_ type: EntityType) -> (String, Color) {
        switch type {
        case .function:  return ("fn", Color(red: 0.55, green: 0.35, blue: 0.75))
        case .method:    return ("m", Color(red: 0.35, green: 0.55, blue: 0.75))
        case .class:     return ("C", Color(red: 0.20, green: 0.60, blue: 0.45))
        case .struct:    return ("S", Color(red: 0.75, green: 0.50, blue: 0.20))
        case .enum:      return ("E", Color(red: 0.65, green: 0.30, blue: 0.30))
        case .protocol:  return ("P", Color(red: 0.30, green: 0.50, blue: 0.70))
        case .component: return ("V", Color(red: 0.45, green: 0.65, blue: 0.35))
        case .hook:      return ("H", Color(red: 0.60, green: 0.45, blue: 0.55))
        }
    }

    // MARK: Shared UI Atoms

    private func metadataRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textSecondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(textPrimary)
                .textSelection(.enabled)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func understandingLayer(_ label: String?, text: String?, available: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                HStack(spacing: 6) {
                    Circle()
                        .fill(available ? subtleGreen : textSecondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(textSecondary)
                        .textCase(.uppercase)
                }
            }
            if let text, available {
                Text(text)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !available {
                notGeneratedPill()
            }
        }
    }

    private func layerDot(_ label: String, active: Bool) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(active ? subtleGreen : textSecondary.opacity(0.3))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? textPrimary : textSecondary.opacity(0.5))
        }
    }

    private func timelineEvent(_ label: String, date: Date) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(accentOrange.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textPrimary)
            Spacer()
            Text(formatRelativeDate(date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(textSecondary)
        }
    }

    private func relationshipSubHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(textSecondary)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(textSecondary)
                .textCase(.uppercase)
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(textSecondary.opacity(0.6))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(cardBorder))
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func relationshipEdge(_ rel: Relationship, entities: [ParsedEntity]) -> some View {
        let sourceName = entities.first { $0.entity.stableId == rel.sourceEntity }?.entity.name ?? rel.sourceEntity
        return HStack(spacing: 4) {
            Text(sourceName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(textPrimary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(textSecondary.opacity(0.5))
            Text(rel.targetName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(subtleBlue)
                .lineLimit(1)
            Spacer()
            Text("L\(rel.line)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(textSecondary.opacity(0.4))
        }
        .padding(.vertical, 1)
    }

    private func importKindBadge(_ kind: ImportKind) -> some View {
        let (label, color): (String, Color) = switch kind {
        case .module:     ("M", subtleBlue)
        case .symbol:     ("S", Color(red: 0.55, green: 0.35, blue: 0.75))
        case .wildcard:   ("*", accentOrange)
        case .sideEffect: ("!", Color(red: 0.65, green: 0.30, blue: 0.30))
        }
        return Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
    }

    private var codeBlockBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(cardBorder, lineWidth: 1)
            )
    }

    // MARK: Formatting Helpers

    private func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatNumber(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        return String(format: "%.1fk", Double(n) / 1000.0)
    }

    // MARK: - Empty & Error States (reused)

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(textSecondary.opacity(0.5))

            Text("Open a code file or project folder to see what Decode knows")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textSecondary)

            HStack(spacing: 12) {
                Button {
                    viewModel.openFile()
                } label: {
                    Label("Select File", systemImage: "doc")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(accentOrange)

                Button {
                    viewModel.openDirectory()
                } label: {
                    Label("Select Folder", systemImage: "folder")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(accentOrange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(red: 0.90, green: 0.30, blue: 0.24))
                .font(.system(size: 13, weight: .medium))

            Button("Try Again") {
                viewModel.openFile()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Entity Group

private struct EntityGroup {
    let parent: ParsedEntity
    let children: [ParsedEntity]
}

// MARK: - Flow Layout (for pills/tags)

/// Simple horizontal flow layout that wraps to the next line.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct ArrangeResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
            totalHeight = max(totalHeight, y + rowHeight)
        }

        return ArrangeResult(size: CGSize(width: totalWidth, height: totalHeight), positions: positions)
    }
}

// MARK: - Entity Detail View (reused intact)

private struct EntityDetailView: View {
    let parsed: ParsedEntity
    let parentName: String?
    let children: [ParsedEntity]
    let accentOrange: Color
    let cardBorder: Color
    let textPrimary: Color
    let textSecondary: Color
    let warmBackground: Color

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    entityTypeBadge
                    VStack(alignment: .leading, spacing: 2) {
                        Text(parsed.entity.name)
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                            .foregroundStyle(textPrimary)
                        Text(parsed.entity.entityType.rawValue.capitalized)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(textSecondary)
                    }
                }

                Divider().overlay(cardBorder)
                metadataSection

                if parentName != nil || !children.isEmpty {
                    Divider().overlay(cardBorder)
                    relationshipsSection
                }

                Divider().overlay(cardBorder)
                signatureSection

                Divider().overlay(cardBorder)
                sourceSection
            }
            .padding(16)
        }
        .background(warmBackground.opacity(0.5))
    }

    private var entityTypeBadge: some View {
        let (icon, color) = iconForType(parsed.entity.entityType)
        return Text(icon)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(color, in: RoundedRectangle(cornerRadius: 8))
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Details")
            metadataRow(label: "File", value: parsed.fileName)
            metadataRow(label: "Location", value: parsed.lineRangeDescription)
            metadataRow(label: "Size", value: "\(parsed.endLine - parsed.startLine + 1) lines")
            metadataRow(label: "Hash", value: String(parsed.entity.hash.prefix(16)) + "...")
        }
    }

    private var relationshipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Relationships")

            if let parent = parentName {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(textSecondary)
                    Text("Member of")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(textSecondary)
                    Text(parent)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accentOrange)
                }
            }

            if !children.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(textSecondary)
                    Text("Contains \(children.count) member\(children.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(textSecondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(children) { child in
                        HStack(spacing: 6) {
                            let (icon, color) = iconForType(child.entity.entityType)
                            Text(icon)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(color, in: RoundedRectangle(cornerRadius: 4))

                            let shortName: String = {
                                if let dot = child.entity.name.lastIndex(of: ".") {
                                    return String(child.entity.name[child.entity.name.index(after: dot)...])
                                }
                                return child.entity.name
                            }()

                            Text(shortName)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(textPrimary)

                            Spacer()

                            Text(child.lineRangeDescription)
                                .font(.system(size: 10))
                                .foregroundStyle(textSecondary.opacity(0.7))
                        }
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(cardBorder, lineWidth: 1)
                        )
                )
            }
        }
    }

    private var signatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Signature")
            Text(parsed.signature)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textPrimary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(cardBorder, lineWidth: 1)
                        )
                )
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Source")
            ScrollView(.horizontal, showsIndicators: true) {
                Text(parsed.sourceText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(textPrimary)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: 300, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(cardBorder, lineWidth: 1)
                    )
            )
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(textSecondary)
            .textCase(.uppercase)
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textSecondary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textPrimary)
                .textSelection(.enabled)
        }
    }

    private func iconForType(_ type: EntityType) -> (String, Color) {
        switch type {
        case .function:  return ("fn", Color(red: 0.55, green: 0.35, blue: 0.75))
        case .method:    return ("m", Color(red: 0.35, green: 0.55, blue: 0.75))
        case .class:     return ("C", Color(red: 0.20, green: 0.60, blue: 0.45))
        case .struct:    return ("S", Color(red: 0.75, green: 0.50, blue: 0.20))
        case .enum:      return ("E", Color(red: 0.65, green: 0.30, blue: 0.30))
        case .protocol:  return ("P", Color(red: 0.30, green: 0.50, blue: 0.70))
        case .component: return ("V", Color(red: 0.45, green: 0.65, blue: 0.35))
        case .hook:      return ("H", Color(red: 0.60, green: 0.45, blue: 0.55))
        }
    }
}

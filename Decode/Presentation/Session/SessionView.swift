import SwiftUI

/// The main view for Session Mode.
///
/// Three-column layout:
/// 1. Session list sidebar (left) — all open sessions with active indicator
/// 2. Entity list (center) — hierarchical entities from the active session
/// 3. Detail inspector (right) — metadata for the selected entity
struct SessionView: View {

    @Bindable var viewModel: SessionViewModel

    /// Tracks which parent entities are expanded in the list.
    @State private var collapsedParents: Set<String> = []

    // MARK: - WhisperFlow-inspired palette (matches ContentView/HUD)

    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)

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
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accentOrange)

            Text(viewModel.fileName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(textPrimary)
                .lineLimit(1)

            if viewModel.isWatching {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(red: 0.30, green: 0.69, blue: 0.31))
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

            Text("\(viewModel.allSessions.count) session\(viewModel.allSessions.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textSecondary)

            Button {
                viewModel.openFile()
            } label: {
                Label("Open File", systemImage: "folder")
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
        } else if viewModel.allSessions.isEmpty && viewModel.activeSession == nil {
            emptyState
        } else {
            mainContent
        }
    }

    // MARK: - Main Content (Session List + Entities + Detail)

    private var mainContent: some View {
        HSplitView {
            // Session list sidebar — always visible when sessions exist
            sessionListPanel
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 240)

            if viewModel.parsedEntities.isEmpty && !viewModel.isLoading {
                // No entities (non-Swift file or empty file)
                noEntitiesView
            } else {
                // Entity list
                entityListPanel
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: 400)

                // Detail inspector
                detailPanel
                    .frame(minWidth: 280, idealWidth: 380)
            }
        }
    }

    // MARK: - Session List Panel

    private var sessionListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(textSecondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    viewModel.openFile()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(accentOrange)
                }
                .buttonStyle(.plain)
                .help("Add Session")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(warmBackground)

            Divider().overlay(cardBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.allSessions) { managed in
                        sessionRow(managed)
                        Divider().overlay(cardBorder.opacity(0.5))
                    }
                }
            }
        }
        .background(warmBackground)
    }

    private func sessionRow(_ managed: ManagedSession) -> some View {
        let isActive = viewModel.activeSessionId == managed.session.id

        return HStack(spacing: 8) {
            // Active indicator
            Circle()
                .fill(isActive ? Color(red: 0.30, green: 0.69, blue: 0.31) : Color.clear)
                .overlay(
                    Circle()
                        .stroke(isActive ? Color.clear : cardBorder, lineWidth: 1)
                )
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(managed.session.fileName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(isActive ? textPrimary : textSecondary)
                    .lineLimit(1)

                Text("\(managed.parsedEntities.count) entities")
                    .font(.system(size: 10))
                    .foregroundStyle(textSecondary.opacity(0.7))
            }

            Spacer()

            // Close button
            Button {
                viewModel.closeSession(id: managed.session.id)
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
            viewModel.switchToSession(id: managed.session.id)
        }
    }

    // MARK: - Entity List Panel

    private var entityListPanel: some View {
        let hierarchy = buildHierarchy()

        return VStack(alignment: .leading, spacing: 0) {
            // Summary bar
            HStack {
                Text("\(viewModel.parsedEntities.count) entities")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(textSecondary)
                Spacer()
                if let refreshed = viewModel.lastRefreshedAt {
                    Text("Updated \(refreshed.formatted(.dateTime.hour().minute().second()))")
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(warmBackground)

            Divider().overlay(cardBorder)

            // Hierarchical entity rows
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hierarchy, id: \.parent.id) { group in
                        // Parent entity row with disclosure chevron
                        parentRow(group.parent, childCount: group.children.count)
                            .onTapGesture {
                                viewModel.selectedEntityID = group.parent.id
                            }
                        Divider().overlay(cardBorder.opacity(0.5))

                        // Child entity rows (indented)
                        if !collapsedParents.contains(group.parent.entity.stableId) {
                            ForEach(group.children) { child in
                                childRow(child)
                                    .onTapGesture {
                                        viewModel.selectedEntityID = child.id
                                    }
                                Divider().overlay(cardBorder.opacity(0.3))
                            }
                        }
                    }
                }
            }
        }
        .background(warmBackground)
    }

    // MARK: - Hierarchy Builder

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

    // MARK: - Detail Panel

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

    // MARK: - Parent Entity Row

    private func parentRow(_ parsed: ParsedEntity, childCount: Int) -> some View {
        let isSelected = viewModel.selectedEntityID == parsed.id
        let isCollapsed = collapsedParents.contains(parsed.entity.stableId)

        return HStack(spacing: 8) {
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

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(parsed.entity.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(textPrimary)

                    if childCount > 0 {
                        Text("\(childCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(textSecondary.opacity(0.7))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(cardBorder)
                            )
                    }
                }

                Text(parsed.lineRangeDescription)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? accentOrange.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Child Entity Row

    private func childRow(_ parsed: ParsedEntity) -> some View {
        let isSelected = viewModel.selectedEntityID == parsed.id
        let shortName: String = {
            if let dotIndex = parsed.entity.name.lastIndex(of: ".") {
                return String(parsed.entity.name[parsed.entity.name.index(after: dotIndex)...])
            }
            return parsed.entity.name
        }()

        return HStack(spacing: 8) {
            Spacer().frame(width: 12)

            entityTypeIcon(parsed.entity.entityType)

            VStack(alignment: .leading, spacing: 2) {
                Text(shortName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(textPrimary)

                Text(parsed.lineRangeDescription)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(textSecondary)
            }

            Spacer()
        }
        .padding(.leading, 32)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
        .background(isSelected ? accentOrange.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(textSecondary.opacity(0.5))

            Text("Open a Swift file to analyze its structure")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textSecondary)

            Button {
                viewModel.openFile()
            } label: {
                Label("Select Swift File", systemImage: "folder")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(accentOrange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No Entities

    private var noEntitiesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(textSecondary.opacity(0.5))

            Text("No code entities found in this file")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Entity Type Icons

    private func entityTypeIcon(_ type: EntityType) -> some View {
        let (icon, color) = iconForType(type)
        return Text(icon)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color, in: RoundedRectangle(cornerRadius: 6))
    }

    private func iconForType(_ type: EntityType) -> (String, Color) {
        switch type {
        case .function: return ("fn", Color(red: 0.55, green: 0.35, blue: 0.75))
        case .method:   return ("m", Color(red: 0.35, green: 0.55, blue: 0.75))
        case .class:    return ("C", Color(red: 0.20, green: 0.60, blue: 0.45))
        case .struct:   return ("S", Color(red: 0.75, green: 0.50, blue: 0.20))
        case .enum:     return ("E", Color(red: 0.65, green: 0.30, blue: 0.30))
        case .protocol: return ("P", Color(red: 0.30, green: 0.50, blue: 0.70))
        case .component: return ("V", Color(red: 0.45, green: 0.65, blue: 0.35))
        case .hook:     return ("H", Color(red: 0.60, green: 0.45, blue: 0.55))
        }
    }

    // MARK: - Error View

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

// MARK: - Entity Detail View

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
        case .function: return ("fn", Color(red: 0.55, green: 0.35, blue: 0.75))
        case .method:   return ("m", Color(red: 0.35, green: 0.55, blue: 0.75))
        case .class:    return ("C", Color(red: 0.20, green: 0.60, blue: 0.45))
        case .struct:   return ("S", Color(red: 0.75, green: 0.50, blue: 0.20))
        case .enum:     return ("E", Color(red: 0.65, green: 0.30, blue: 0.30))
        case .protocol: return ("P", Color(red: 0.30, green: 0.50, blue: 0.70))
        case .component: return ("V", Color(red: 0.45, green: 0.65, blue: 0.35))
        case .hook:     return ("H", Color(red: 0.60, green: 0.45, blue: 0.55))
        }
    }
}

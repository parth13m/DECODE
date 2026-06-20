import SwiftUI

/// SwiftUI content displayed inside the floating session dock panel.
///
/// Renders either a collapsed capsule handle or individual floating session
/// pills based on ``DockState/isExpanded``. Observes ``SessionManager``
/// directly for session state.
///
/// ## Design
/// No container background. Each session is an independent floating capsule
/// with its own `.ultraThinMaterial` backdrop and shadow. The handle is a
/// larger capsule with an orange accent.
///
/// ## Interactions
/// - **Single click**: Activate session (switch context for `⌃⇧Q`).
/// - **Right click**: Context menu (Open Session Mode, Close, Copy Path).
/// - **Hover**: Magnification effect on hovered pill + neighbors.
struct SessionDockContentView: View {

    let sessionManager: SessionManager
    let dockState: DockState
    let onActivateSession: (UUID) -> Void
    let onCloseSession: (UUID) -> Void
    let onOpenSessionMode: (UUID) -> Void
    let onTogglePin: (UUID) -> Void

    // MARK: - WhisperFlow palette (matches existing views)

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88).opacity(0.6)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)
    private let activeGreen = Color(red: 0.30, green: 0.69, blue: 0.31)

    var body: some View {
        if dockState.isExpanded {
            expandedContent
        } else {
            handleView
        }
    }

    // MARK: - Handle (collapsed state)

    /// A capsule-shaped handle visible on the right edge of the screen.
    private var handleView: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
            Capsule()
                .fill(accentOrange.opacity(0.15))
            Capsule()
                .strokeBorder(accentOrange.opacity(0.3), lineWidth: 0.5)

            // Subtle inner dots to hint at draggability
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(accentOrange.opacity(0.4))
                        .frame(width: 3, height: 3)
                }
            }
        }
        .frame(
            width: FloatingSessionDock.handleWidth,
            height: FloatingSessionDock.handleHeight
        )
        .shadow(color: .black.opacity(0.08), radius: 4, x: -1, y: 1)
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                let sessions = sessionManager.orderedSessions
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, managed in
                    sessionPill(managed, index: index)
                }
            }
            // Overflow padding: pills lay out within the central dockWidth region.
            // The extra horizontal/vertical space gives room for scaleEffect to
            // expand without being clipped by the ScrollView or panel bounds.
            .padding(.horizontal, FloatingSessionDock.overflowMargin)
            .padding(.vertical, FloatingSessionDock.overflowMargin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session Pill

    private func sessionPill(_ managed: ManagedSession, index: Int) -> some View {
        let isActive = sessionManager.activeSessionId == managed.session.id
        let isPinned = sessionManager.pinnedSessionId == managed.session.id
        let scale = scaleForIndex(index)
        let isHovered = dockState.hoveredIndex == index

        return HStack(spacing: 7) {
            // Status indicator — pin icon when pinned, circle otherwise
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(accentOrange)
                    .frame(width: 7, height: 7)
            } else {
                Circle()
                    .fill(pillIndicatorColor(managed: managed, isActive: isActive))
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(managed.session.fileName)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !managed.isFileAccessible {
                    Text("File unavailable")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color(red: 0.90, green: 0.30, blue: 0.24))
                } else if !managed.parsedEntities.isEmpty {
                    Text("\(managed.parsedEntities.count) entities")
                        .font(.system(size: 9))
                        .foregroundStyle(textSecondary.opacity(0.7))
                }
            }

            Spacer(minLength: 0)

            // Close button — visible on hover
            if isHovered {
                Button {
                    onCloseSession(managed.session.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(textSecondary.opacity(0.6))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial)
        .background(isActive ? accentOrange.opacity(0.08) : Color.white.opacity(0.5))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    isActive ? accentOrange.opacity(0.4) : cardBorder,
                    lineWidth: 0.5
                )
        )
        .shadow(
            color: .black.opacity(isHovered ? 0.12 : 0.06),
            radius: isHovered ? 6 : 3,
            x: -1,
            y: 1
        )
        .contentShape(Capsule())
        .zIndex(isHovered ? 1 : 0)
        .scaleEffect(scale)
        .animation(.easeOut(duration: 0.15), value: dockState.hoveredIndex)
        .onHover { hovering in
            dockState.hoveredIndex = hovering ? index : nil
        }
        .onTapGesture {
            onActivateSession(managed.session.id)
        }
        .contextMenu {
            Button {
                onOpenSessionMode(managed.session.id)
            } label: {
                Label("Open Session Mode", systemImage: "doc.text.magnifyingglass")
            }

            Button {
                onTogglePin(managed.session.id)
            } label: {
                if isPinned {
                    Label("Unpin Session", systemImage: "pin.slash")
                } else {
                    Label("Pin Session", systemImage: "pin")
                }
            }

            Divider()

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(managed.session.filePath, forType: .string)
            } label: {
                Label("Copy File Path", systemImage: "doc.on.clipboard")
            }

            Divider()

            Button(role: .destructive) {
                onCloseSession(managed.session.id)
            } label: {
                Label("Close Session", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - Magnification

    /// Dock-style magnification: hovered pill scales up, neighbors scale slightly.
    private func scaleForIndex(_ index: Int) -> CGFloat {
        guard let hovered = dockState.hoveredIndex else { return 1.0 }
        let distance = abs(index - hovered)
        switch distance {
        case 0: return 1.22
        case 1: return 1.10
        case 2: return 1.03
        default: return 1.0
        }
    }

    // MARK: - Helpers

    private func pillIndicatorColor(managed: ManagedSession, isActive: Bool) -> Color {
        if !managed.isFileAccessible {
            return Color(red: 0.90, green: 0.30, blue: 0.24)
        }
        return isActive ? activeGreen : cardBorder
    }
}

import SwiftUI

/// Popover showing the current Virtual Session memory state.
///
/// Displays investigations as living knowledge documents — showing each
/// investigation's synthesized understanding, known files and entities,
/// and session statistics. Presented from the "View Memory" button
/// beside the Virtual Session toggle.
struct VirtualSessionInspectorView: View {

    @Environment(AppDependencies.self) private var dependencies

    // MARK: - WhisperFlow palette (matching ContentView)

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)
    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)

    var body: some View {
        let manager = dependencies.virtualSessionManager
        let session = manager.activeSession

        VStack(alignment: .leading, spacing: 0) {
            // Header
            header

            Divider()
                .overlay(cardBorder)

            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        statisticsSection(session: session)

                        if let wm = session.workingMemory, !wm.content.isEmpty {
                            workingMemorySection(wm: wm)
                        }

                        investigationsSection(session: session)
                    }
                    .padding(16)
                }
            } else {
                emptyState
            }

            Divider()
                .overlay(cardBorder)

            // Actions
            actionsBar(hasSession: session != nil)
        }
        .frame(width: 360)
        .frame(minHeight: 200, maxHeight: 500)
        .background(warmBackground)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accentOrange)
            Text("Virtual Session Memory")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Statistics

    private func statisticsSection(session: VirtualSession) -> some View {
        HStack(spacing: 16) {
            statBadge(
                label: "Investigations",
                value: "\(session.investigations.count)"
            )
            statBadge(
                label: "Insights",
                value: "\(session.totalInsightCount)"
            )
            statBadge(
                label: "Memory",
                value: formattedMemorySize(session: session)
            )
        }
    }

    private func statBadge(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(textPrimary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(cardBorder, lineWidth: 1)
                )
        )
    }

    // MARK: - Retrieved Insights ("Used for this explanation")

    private func retrievedInsightsSection(insights: [Insight]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.30, green: 0.69, blue: 0.31))
                Text("Used for this explanation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(textPrimary)
            }

            ForEach(insights) { insight in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.30, green: 0.69, blue: 0.31).opacity(0.5))
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)
                    Text(insight.understanding)
                        .font(.system(size: 11))
                        .foregroundStyle(textSecondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.30, green: 0.69, blue: 0.31).opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 0.30, green: 0.69, blue: 0.31).opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Working Memory

    private func workingMemorySection(wm: WorkingMemory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                    .foregroundStyle(accentOrange)
                Text("Working Memory")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(textPrimary)
                Spacer()
                if wm.compressionCount > 0 {
                    Text("\(wm.compressionCount)x compressed")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
                Text("\(wm.content.count) chars")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(textSecondary)
            }

            Text(wm.content)
                .font(.system(size: 11))
                .foregroundStyle(textPrimary.opacity(0.85))
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)

            if !wm.topicKeywords.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "tag")
                        .font(.system(size: 9))
                        .foregroundStyle(textSecondary.opacity(0.7))
                        .frame(width: 12)
                        .padding(.top, 1)
                    Text(wm.topicKeywords.suffix(10).joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(textSecondary.opacity(0.7))
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(accentOrange.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(accentOrange.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Investigations

    private func investigationsSection(session: VirtualSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(session.investigations.enumerated().reversed()), id: \.element.id) { index, investigation in
                investigationCard(
                    investigation: investigation,
                    isActive: index == session.investigations.count - 1
                )
            }
        }
    }

    private func investigationCard(investigation: Investigation, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title row with active indicator and evidence count.
            HStack(spacing: 6) {
                if isActive {
                    Circle()
                        .fill(accentOrange)
                        .frame(width: 6, height: 6)
                }
                Text(investigation.theme)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(investigation.insights.count) evidence")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.94, green: 0.93, blue: 0.91))
                    )
            }

            // Current Understanding — the canonical knowledge.
            if let understanding = investigation.currentUnderstanding, !understanding.isEmpty {
                Text(understanding)
                    .font(.system(size: 11))
                    .foregroundStyle(textPrimary.opacity(0.85))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Legacy fallback: show raw insights when no synthesized knowledge exists.
                ForEach(investigation.insights) { insight in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: modeIcon(insight.mode))
                            .font(.system(size: 9))
                            .foregroundStyle(textSecondary)
                            .frame(width: 12)
                            .padding(.top, 2)
                        Text(insight.understanding)
                            .font(.system(size: 11))
                            .foregroundStyle(textSecondary)
                            .lineLimit(2)
                    }
                }
            }

            // Known files and entities metadata.
            if let files = investigation.knownFiles, !files.isEmpty {
                metadataRow(icon: "doc.text", items: files.sorted())
            }
            if let entities = investigation.knownEntities, !entities.isEmpty {
                metadataRow(icon: "chevron.left.forwardslash.chevron.right", items: Array(entities.sorted().prefix(5)))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isActive ? accentOrange.opacity(0.3) : cardBorder, lineWidth: 1)
                )
        )
    }

    private func metadataRow(icon: String, items: [String]) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(textSecondary.opacity(0.7))
                .frame(width: 12)
                .padding(.top, 1)
            Text(items.joined(separator: ", "))
                .font(.system(size: 10))
                .foregroundStyle(textSecondary.opacity(0.7))
                .lineLimit(2)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 24))
                .foregroundStyle(textSecondary.opacity(0.5))
            Text("No active session")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textSecondary)
            Text("Enable Virtual Session to start recording investigation context.")
                .font(.system(size: 11))
                .foregroundStyle(textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Actions

    private func actionsBar(hasSession: Bool) -> some View {
        HStack {
            if hasSession {
                Button {
                    dependencies.virtualSessionManager.endSession()
                    dependencies.virtualSessionManager.startSession()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("Clear Session")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func modeIcon(_ mode: InsightMode) -> String {
        switch mode {
        case .selection: return "text.cursor"
        case .screenshot: return "camera.viewfinder"
        case .session: return "doc.text.magnifyingglass"
        case .followUp: return "bubble.left"
        }
    }

    private func formattedMemorySize(session: VirtualSession) -> String {
        let chars = session.totalCharacterCount
        if chars < 1000 {
            return "\(chars) chars"
        } else {
            let kb = Double(chars) / 1000.0
            return String(format: "%.1fK", kb)
        }
    }
}

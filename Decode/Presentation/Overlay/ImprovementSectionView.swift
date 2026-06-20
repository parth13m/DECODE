import SwiftUI

/// Displays the code improvement result inside the explanation HUD.
///
/// Shows three sections:
/// 1. **Summary** — why the improved version is better
/// 2. **Original Code** — the user's original code for comparison
/// 3. **Improved Code** — the AI-generated improvement
///
/// Action buttons: Copy, Replace, and Cancel.
/// Follows the same visual style as the existing follow-up and explanation sections.
struct ImprovementSectionView: View {

    @Bindable var viewModel: ExplanationHUDViewModel

    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let accentGreen = Color(red: 0.22, green: 0.65, blue: 0.36)

    /// Whether the "Copied!" confirmation is showing.
    @State private var showCopiedConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            Divider()
                .overlay(Color(red: 0.91, green: 0.90, blue: 0.88))
                .padding(.top, 4)

            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(accentOrange)

                Text("Improve Code")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if viewModel.isImprovementLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accentOrange)
                }
            }

            // Loading state
            if viewModel.isImprovementLoading && viewModel.improvedCode.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accentOrange)
                    Text("Improving...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Error state
            if !viewModel.improvementError.isEmpty {
                Label(viewModel.improvementError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.system(size: 11, weight: .medium))
            }

            // Summary
            if !viewModel.improvementSummary.isEmpty {
                summaryView
            }

            // Original code
            if !viewModel.improvedCode.isEmpty {
                originalCodeView
            }

            // Improved code
            if !viewModel.improvedCode.isEmpty {
                improvedCodeView
            }

            // Warning + action buttons + confirmation/error
            if !viewModel.improvedCode.isEmpty {
                replacementWarning
                actionButtons
                replacementFeedback
            }

            // Dismiss button for summary-only (no-improvement) results
            if viewModel.improvedCode.isEmpty && !viewModel.improvementSummary.isEmpty && !viewModel.isImprovementLoading {
                dismissButton
            }
        }
    }

    // MARK: - Summary

    private var summaryView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accentOrange)
                .padding(.top, 2)

            Text(viewModel.improvementSummary)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(red: 0.97, green: 0.95, blue: 0.92))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(accentOrange)
                .frame(width: 3)
        }
    }

    // MARK: - Original Code

    private var originalCodeView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Original")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            codeBlock(viewModel.followUpContextOriginalCode)
        }
    }

    // MARK: - Improved Code

    private var improvedCodeView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Improved")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accentGreen)
                .textCase(.uppercase)

            codeBlock(viewModel.improvedCode, accent: accentGreen)
        }
    }

    // MARK: - Code Block

    private func codeBlock(_ code: String, accent: Color? = nil) -> some View {
        let borderColor = accent ?? Color(red: 0.88, green: 0.87, blue: 0.85)

        return ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.25, green: 0.25, blue: 0.25))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.95, green: 0.94, blue: 0.93))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Replacement Warning

    private var replacementWarning: some View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Make sure your original code selection is still active before pressing Replace.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 8) {
            // Copy button
            Button {
                viewModel.copyImprovedCode()
                showCopiedConfirmation = true

                // Auto-dismiss confirmation after 2 seconds.
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showCopiedConfirmation = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showCopiedConfirmation ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                    Text(showCopiedConfirmation ? "Copied!" : "Copy")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(showCopiedConfirmation ? accentGreen : accentOrange)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            // Replace button
            Button {
                viewModel.replaceInEditor()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 10))
                    Text("Replace")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(viewModel.canReplace ? accentGreen : Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canReplace)

            // Cancel button
            Button {
                viewModel.cancelImprovement()
            } label: {
                Text("Cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.92, green: 0.91, blue: 0.90))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Dismiss Button (No-Improvement Path)

    private var dismissButton: some View {
        HStack {
            Button {
                viewModel.cancelImprovement()
            } label: {
                Text("Dismiss")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.92, green: 0.91, blue: 0.90))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, 2)
    }

    // MARK: - Replacement Feedback

    @ViewBuilder
    private var replacementFeedback: some View {
        if !viewModel.replacementConfirmation.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(accentGreen)
                Text(viewModel.replacementConfirmation)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(accentGreen)
            }
        }

        if !viewModel.replacementError.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(viewModel.replacementError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
    }
}

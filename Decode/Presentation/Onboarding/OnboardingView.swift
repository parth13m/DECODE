import SwiftUI

/// First-run onboarding view that introduces Decode's three modes and
/// required permissions.
///
/// Displayed as a sheet on first launch. Can be reopened from the Help menu.
/// If the user is not yet authenticated, shows the invite code step first.
/// Completion is tracked via `UserDefaults.hasCompletedOnboarding`.
struct OnboardingView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(AppDependencies.self) private var dependencies

    /// Callback fired when the user taps "Open Settings" (Cmd+,).
    var onOpenSettings: (() -> Void)?

    // MARK: - WhisperFlow palette (matches ContentView)

    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)
    private let activeGreen = Color(red: 0.30, green: 0.69, blue: 0.31)

    // MARK: - Invite Code State

    @State private var inviteCode: String = ""
    @State private var inviteError: String?
    @State private var isActivating = false

    // MARK: - Permission State

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var inputMonitoringGranted = CGPreflightListenEventAccess()
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    /// Whether the invite step should be shown.
    private var needsInvite: Bool {
        dependencies.authService.state != .authenticated
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                heroSection

                if needsInvite {
                    inviteSection
                } else {
                    modesSection
                    permissionsSection
                    actionsSection
                }
            }
            .padding(32)
        }
        .frame(width: 520, height: 620)
        .background(warmBackground)
        .onReceive(refreshTimer) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            inputMonitoringGranted = CGPreflightListenEventAccess()
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(accentOrange.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(accentOrange)
            }

            Text("Welcome to Decode")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(textPrimary)

            Text("Understand code without leaving your workflow.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(textSecondary)
        }
    }

    // MARK: - Invite Code Step

    private var inviteSection: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("INVITE CODE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(textSecondary)
                    .textCase(.uppercase)

                TextField("DECODE-XXXX-XXXX", text: $inviteCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .autocorrectionDisabled()
                    .onSubmit { activateInvite() }
            }

            if let inviteError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Text(inviteError)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }
            }

            Button {
                activateInvite()
            } label: {
                HStack(spacing: 8) {
                    if isActivating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isActivating ? "Activating..." : "Activate")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentOrange)
            .disabled(inviteCode.trimmingCharacters(in: .whitespaces).isEmpty || isActivating)

            Text("Contact your Decode admin if you don't have a code.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textSecondary.opacity(0.7))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(cardBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        )
    }

    private func activateInvite() {
        let code = inviteCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, !isActivating else { return }

        isActivating = true
        inviteError = nil

        Task {
            do {
                try await dependencies.authService.activateInviteCode(code)
                dependencies.rebuildAIProvider()
                // On success, the view will re-render showing modes/permissions
                // because needsInvite becomes false.
            } catch let error as AuthError {
                inviteError = error.errorDescription
            } catch {
                inviteError = "Connection failed. Check your internet and try again."
            }
            isActivating = false
        }
    }

    // MARK: - Three Modes

    private var modesSection: some View {
        VStack(spacing: 10) {
            modeCard(
                icon: "text.cursor",
                title: "Selection Mode",
                hotkey: "\u{2303}\u{2303}",
                hotkeyLabel: "Double Control",
                description: "Select text in any app, double-tap Control to get an AI explanation."
            )

            modeCard(
                icon: "camera.viewfinder",
                title: "Screenshot Mode",
                hotkey: "\u{2325}\u{2325}",
                hotkeyLabel: "Double Option",
                description: "Drag to capture a screen region. Text is extracted and explained."
            )

            modeCard(
                icon: "doc.text.magnifyingglass",
                title: "Session Mode",
                hotkey: "\u{21E7}\u{21E7}",
                hotkeyLabel: "Double Shift",
                description: "Open a file, then ask context-aware questions about any snippet."
            )
        }
    }

    private func modeCard(
        icon: String,
        title: String,
        hotkey: String,
        hotkeyLabel: String,
        description: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(accentOrange)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(accentOrange.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(textPrimary)

                    Text(hotkey)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: 0.94, green: 0.93, blue: 0.91))
                        )
                }

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(cardBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.02), radius: 4, y: 1)
        )
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Required Permissions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(textSecondary)
                .textCase(.uppercase)

            VStack(spacing: 6) {
                permissionRow(
                    name: "Accessibility",
                    granted: accessibilityGranted,
                    purpose: "Text capture from other apps"
                )
                permissionRow(
                    name: "Input Monitoring",
                    granted: inputMonitoringGranted,
                    purpose: "Global hotkey detection"
                )
                permissionRow(
                    name: "Screen Recording",
                    granted: screenRecordingGranted,
                    purpose: "Screenshot Mode capture"
                )
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(cardBorder, lineWidth: 1)
                    )
            )

            if !accessibilityGranted || !inputMonitoringGranted || !screenRecordingGranted {
                Button {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
                    )
                } label: {
                    Label("Open System Settings", systemImage: "gear")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
    }

    private func permissionRow(name: String, granted: Bool, purpose: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(granted ? activeGreen : textSecondary.opacity(0.4))

            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textPrimary)

            Spacer()

            Text(purpose)
                .font(.system(size: 11))
                .foregroundStyle(textSecondary)
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button {
                onOpenSettings?()
                completeOnboarding()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(accentOrange)

            Button {
                completeOnboarding()
            } label: {
                Text("Get Started")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentOrange)
        }
    }

    private func completeOnboarding() {
        OnboardingState.markCompleted()
        dismiss()
    }
}

// MARK: - Onboarding State

/// Tracks whether the user has completed the onboarding flow.
///
/// Uses UserDefaults for persistence. Separate enum to avoid polluting
/// view code with defaults key management.
enum OnboardingState {

    private static let completedKey = "hasCompletedOnboarding"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: completedKey)
    }
}

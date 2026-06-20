import SwiftUI

/// Invite code entry view for Decode authentication.
///
/// Shown when the user is not authenticated. Handles invite code input,
/// activation via ``AuthService``, and error display.
struct InviteCodeView: View {

    @Environment(AppDependencies.self) private var dependencies
    @State private var inviteCode: String = ""
    @State private var errorMessage: String?
    @State private var isActivating = false

    // MARK: - WhisperFlow palette

    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App identity
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(accentOrange.opacity(0.12))
                        .frame(width: 76, height: 76)
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(accentOrange)
                }

                VStack(spacing: 6) {
                    Text("Decode")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(textPrimary)
                    Text("Enter your invite code to get started.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
            }

            Spacer().frame(height: 36)

            // Invite code input card
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
                        .onSubmit { activate() }
                }

                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }

                Button {
                    activate()
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
            .padding(.horizontal, 80)

            Spacer().frame(height: 20)

            Text("Contact your Decode admin if you don't have a code.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textSecondary.opacity(0.7))

            Spacer()
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(warmBackground)
    }

    // MARK: - Activation

    private func activate() {
        let code = inviteCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, !isActivating else { return }

        isActivating = true
        errorMessage = nil

        Task {
            do {
                try await dependencies.authService.activateInviteCode(code)
                dependencies.rebuildAIProvider()
            } catch let error as AuthError {
                errorMessage = error.errorDescription
            } catch {
                errorMessage = "Connection failed. Check your internet and try again."
            }
            isActivating = false
        }
    }
}

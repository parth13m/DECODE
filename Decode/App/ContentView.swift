import SwiftUI

/// The root view of the application.
///
/// Displays a welcome state with guidance to configure the AI provider
/// via the Settings window (Cmd+,).
struct ContentView: View {

    @Environment(AppDependencies.self) private var dependencies
    @State private var showingSession = false
    @State private var showingOnboarding = !OnboardingState.hasCompleted
    @State private var showingMemoryInspector = false
    @AppStorage("dsaModeEnabled") private var dsaModeEnabled = false
    @AppStorage("virtualSessionEnabled") private var virtualSessionEnabled = false
    @AppStorage("enhancedExplanationEnabled") private var enhancedExplanationEnabled = false

    // MARK: - WhisperFlow-inspired palette

    private let warmBackground = Color(red: 0.98, green: 0.97, blue: 0.95)
    private let accentOrange = Color(red: 0.91, green: 0.47, blue: 0.18)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)
    private let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.12)
    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)

    var body: some View {
        Group {
            switch dependencies.authService.state {
            case .authenticating:
                authLoadingView
            case .needsInvite, .error:
                InviteCodeView()
                    .environment(dependencies)
            case .disabled:
                disabledView
            case .offline:
                offlineView
            case .authenticated:
                authenticatedContent
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(warmBackground)
        .background(WindowCloseButtonFix())
    }

    // MARK: - Authenticated Content

    private var authenticatedContent: some View {
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
                    Text("Developer AI Companion")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(textSecondary)
                }
            }

            Spacer().frame(height: 32)

            // Status card
            VStack(spacing: 14) {
                if !dependencies.isConfigured {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting to Decode Gateway...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(textSecondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(red: 0.30, green: 0.69, blue: 0.31))
                        Text("AI provider configured")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(textPrimary)
                    }

                    Divider()
                        .overlay(cardBorder)

                    VStack(spacing: 8) {
                        hotkeyRow(key: "\u{2303}\u{2303}", action: "Explain selected text")
                        hotkeyRow(key: "\u{2325}\u{2325}", action: "Screenshot & explain")
                        hotkeyRow(key: "\u{21E7}\u{21E7}", action: "Ask with session context")
                        hotkeyRow(key: "\u{2303}\u{21E7}O", action: "Open session file")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(cardBorder, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
            )
            .padding(.horizontal, 60)

            Spacer().frame(height: 12)

            // DSA Mode toggle
            HStack(spacing: 10) {
                Toggle("DSA Mode", isOn: $dsaModeEnabled)
                    .toggleStyle(.switch)
                    .tint(accentOrange)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textPrimary)
                Text("Algorithms & Interview Prep")
                    .font(.system(size: 11))
                    .foregroundStyle(textSecondary)
                Spacer()
            }
            .padding(.horizontal, 60)

            // Virtual Session toggle
            HStack(spacing: 10) {
                Toggle("Virtual Session", isOn: $virtualSessionEnabled)
                    .toggleStyle(.switch)
                    .tint(accentOrange)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textPrimary)
                Text("Remember investigation context")
                    .font(.system(size: 11))
                    .foregroundStyle(textSecondary)
                Spacer()
                if virtualSessionEnabled {
                    Button {
                        showingMemoryInspector.toggle()
                    } label: {
                        Text("View Memory")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accentOrange)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingMemoryInspector) {
                        VirtualSessionInspectorView()
                            .environment(dependencies)
                    }
                }
            }
            .padding(.horizontal, 60)
            .onChange(of: virtualSessionEnabled) { _, newValue in
                dependencies.virtualSessionManager.handleToggleChanged(enabled: newValue)
            }

            // Enhanced Explanation toggle
            HStack(spacing: 10) {
                Toggle("Enhanced Explanation", isOn: $enhancedExplanationEnabled)
                    .toggleStyle(.switch)
                    .tint(accentOrange)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textPrimary)
                Text("Screen context for richer explanations")
                    .font(.system(size: 11))
                    .foregroundStyle(textSecondary)
                Spacer()
            }
            .padding(.horizontal, 60)

            #if DEBUG
            // Temporary debug UI: show most recent Visual Context
            if enhancedExplanationEnabled {
                EnhancedExplanationDebugView()
                    .padding(.horizontal, 60)
            }
            #endif

            Spacer().frame(height: 12)

            // Permission status
            PermissionStatusView()
                .padding(.horizontal, 60)

            Spacer().frame(height: 20)

            // Session Mode entry point
            Button {
                showingSession = true
            } label: {
                Label("Open Session Mode", systemImage: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(accentOrange)

            Spacer()
        }
        .sheet(isPresented: $showingSession) {
            if let vm = dependencies.sessionViewModel {
                SessionView(viewModel: vm)
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(onOpenSettings: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            showingOnboarding = true
        }
        .onChange(of: dependencies.sessionViewModel?.shouldPresentSession) { _, newValue in
            if newValue == true {
                showingSession = true
                dependencies.sessionViewModel?.shouldPresentSession = false
            }
        }
    }

    // MARK: - Auth State Views

    private var authLoadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Verifying account...")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(textSecondary)
        }
    }

    private var disabledView: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.red.opacity(0.10))
                    .frame(width: 76, height: 76)
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.red)
            }

            VStack(spacing: 8) {
                Text("Account Disabled")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(textPrimary)

                Text("Contact Decode support if you believe this is a mistake.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var offlineView: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(accentOrange.opacity(0.12))
                    .frame(width: 76, height: 76)
                Image(systemName: "wifi.slash")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(accentOrange)
            }

            VStack(spacing: 8) {
                Text("Unable to Verify Account")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(textPrimary)

                Text("Check your internet connection.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(textSecondary)
            }

            Button {
                Task {
                    await dependencies.authService.retryValidation()
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(accentOrange)
        }
    }

    // MARK: - Hotkey Badge

    private func hotkeyRow(key: String, action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(red: 0.94, green: 0.93, blue: 0.91))
                )
            Text(action)
                .font(.system(size: 12))
                .foregroundStyle(textSecondary)
            Spacer()
        }
    }
}

/// Workaround for SwiftUI WindowGroup close button not responding.
///
/// SwiftUI's internal window delegate can block `performClose:` by returning
/// `false` from `windowShouldClose:`. This rewires the standard close button
/// to call `close()` directly, bypassing the delegate check.
private struct WindowCloseButtonFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = CloseButtonFixView()
        DispatchQueue.main.async {
            view.installFix()
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class CloseButtonFixView: NSView {

    func installFix() {
        guard let window = self.window,
              let closeButton = window.standardWindowButton(.closeButton)
        else { return }

        closeButton.target = self
        closeButton.action = #selector(handleClose(_:))
    }

    @objc func handleClose(_ sender: Any?) {
        window?.close()
    }
}

// MARK: - Permission Status

/// Displays the status of required macOS permissions with actionable guidance.
///
/// Checks Accessibility (via `AXIsProcessTrusted()`), Input Monitoring
/// (via `CGPreflightListenEventAccess()`), and Screen Recording
/// (via `CGPreflightScreenCaptureAccess()`) independently.
private struct PermissionStatusView: View {

    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var inputMonitoringGranted = CGPreflightListenEventAccess()
    @State private var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    private let textSecondary = Color(red: 0.50, green: 0.49, blue: 0.47)
    private let cardBorder = Color(red: 0.91, green: 0.90, blue: 0.88)

    /// Timer-driven refresh so status updates after the user grants permissions
    /// in System Settings without restarting the app.
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        let allGranted = accessibilityGranted && inputMonitoringGranted && screenRecordingGranted

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: allGranted ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(allGranted ? Color(red: 0.30, green: 0.69, blue: 0.31) : .orange)
                Text("Permissions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
                Spacer()
                if !allGranted {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
                        )
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }

            permissionRow(
                name: "Accessibility",
                granted: accessibilityGranted,
                hint: "Required for text capture. Grant in Privacy & Security \u{2192} Accessibility."
            )
            permissionRow(
                name: "Input Monitoring",
                granted: inputMonitoringGranted,
                hint: "Required for hotkeys. Grant in Privacy & Security \u{2192} Input Monitoring."
            )
            permissionRow(
                name: "Screen Recording",
                granted: screenRecordingGranted,
                hint: "Required for Screenshot Mode. Grant in Privacy & Security \u{2192} Screen Recording."
            )

            if !allGranted {
                Text("Restart Decode after granting permissions.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(textSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(cardBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.02), radius: 4, y: 1)
        )
        .onReceive(refreshTimer) { _ in
            accessibilityGranted = AXIsProcessTrusted()
            inputMonitoringGranted = CGPreflightListenEventAccess()
            screenRecordingGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private func permissionRow(name: String, granted: Bool, hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(granted ? Color(red: 0.30, green: 0.69, blue: 0.31) : .red)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            if !granted {
                Text("— \(hint)")
                    .font(.system(size: 10))
                    .foregroundStyle(textSecondary)
            }
            Spacer()
        }
    }
}

#if DEBUG
// MARK: - Enhanced Explanation Debug View (temporary)

/// Displays the most recent Visual Context for debugging.
/// **Remove once Enhanced Explanation is verified working.**
///
/// Reads directly from `EnhancedExplanationDebug.shared` which is `@Observable`.
/// SwiftUI tracks property access in `body` and re-renders automatically.
private struct EnhancedExplanationDebugView: View {

    var debug = EnhancedExplanationDebug.shared

    private let mono = Font.system(size: 12, design: .monospaced)
    private let monoSmall = Font.system(size: 11, design: .monospaced)
    private let monoBold = Font.system(size: 12, weight: .semibold, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar.
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Text("Enhanced Explanation Debug")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.purple.opacity(0.8))

            // Error banner — prominent, at the top.
            if let error = debug.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.octagon.fill")
                        .foregroundStyle(.white)
                    Text(error)
                        .font(mono)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.85))
            }

            // Status row.
            VStack(alignment: .leading, spacing: 6) {
                debugStatusRow
                Divider().background(Color.white.opacity(0.2))
                debugParsedSection
                Divider().background(Color.white.opacity(0.2))
                debugRawSection
            }
            .padding(12)
        }
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.purple.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: - Status Row

    @ViewBuilder
    private var debugStatusRow: some View {
        let hasVC = debug.lastVisualContext != nil
        let hasError = debug.lastError != nil

        HStack(spacing: 12) {
            // Status badge.
            if hasVC {
                Text("SUCCESS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if hasError {
                Text("FAILURE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Text("WAITING")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            // Latency.
            if let ms = debug.lastLatencyMs {
                HStack(spacing: 4) {
                    Text("Latency:")
                        .font(monoSmall)
                        .foregroundStyle(.gray)
                    Text("\(String(format: "%.0f", ms))ms")
                        .font(monoBold)
                        .foregroundStyle(.orange)
                }
            }

            // Evidence count.
            if let vc = debug.lastVisualContext {
                HStack(spacing: 4) {
                    Text("Items:")
                        .font(monoSmall)
                        .foregroundStyle(.gray)
                    Text("\(vc.items.count)")
                        .font(monoBold)
                        .foregroundStyle(.cyan)
                }
            }

            Spacer()

            // Timestamp.
            if let ts = debug.lastTimestamp {
                HStack(spacing: 4) {
                    Text(ts, style: .relative)
                        .font(monoSmall)
                        .foregroundStyle(.gray)
                    Text("ago")
                        .font(monoSmall)
                        .foregroundStyle(.gray)
                }
            }
        }
    }

    // MARK: - Parsed Visual Context Section

    @ViewBuilder
    private var debugParsedSection: some View {
        Text("──── Parsed Visual Context ────")
            .font(monoBold)
            .foregroundStyle(.purple)

        if let vc = debug.lastVisualContext, !vc.items.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vc.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 6) {
                            Text(item.type + ":")
                                .font(monoBold)
                                .foregroundStyle(.cyan)
                            Text(item.content)
                                .font(mono)
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
        } else {
            Text("(none)")
                .font(mono)
                .foregroundStyle(.gray)
        }
    }

    // MARK: - Raw Vision Response Section

    @ViewBuilder
    private var debugRawSection: some View {
        Text("──── Raw Vision Response ────")
            .font(monoBold)
            .foregroundStyle(.purple)

        if let raw = debug.lastRawResponse, !raw.isEmpty {
            ScrollView {
                Text(raw)
                    .font(mono)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
        } else {
            Text("(none)")
                .font(mono)
                .foregroundStyle(.gray)
        }
    }
}
#endif

#Preview {
    ContentView()
        .environment(AppDependencies())
}


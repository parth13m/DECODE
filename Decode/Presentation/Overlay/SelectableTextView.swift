// SelectableTextView.swift — Decode Presentation
// Anchored Follow-Up: NSTextView-backed selectable text with contextual Reply button.
//
// SwiftUI's .textSelection(.enabled) does not expose the selected text
// programmatically. This component wraps an AppKit NSTextView to track
// selection changes and display a contextual "Reply ↩" button near the
// selected text.

import AppKit
import SwiftUI

/// A selectable text view that tracks user selection and shows a contextual Reply button.
///
/// Wraps an AppKit NSTextView (via NSViewRepresentable) to get programmatic access to
/// selected text. The Reply button is a SwiftUI overlay positioned relative to the
/// selection using coordinates from NSLayoutManager.
struct SelectableTextView: View {

    let attributedString: AttributedString
    let blockID: SelectableBlockID
    let activeSelectionBlockID: SelectableBlockID?
    let onSelectionChange: (SelectableBlockID, String?) -> Void
    let onReply: () -> Void

    @State private var selectionAnchor: CGPoint?
    @State private var clearTrigger: Int = 0
    @State private var reportedHeight: CGFloat = 20
    @State private var reportedWidth: CGFloat = 300

    var body: some View {
        ZStack(alignment: .topLeading) {
            SelectableTextViewRepresentable(
                attributedString: attributedString,
                reportedHeight: $reportedHeight,
                reportedWidth: $reportedWidth,
                clearTrigger: $clearTrigger,
                onSelectionChange: { text, rect in
                    if let text, !text.isEmpty, let rect {
                        let buttonWidth: CGFloat = 80
                        let buttonHeight: CGFloat = 28
                        let gap: CGFloat = 4

                        // Preferred: below selection, horizontally centered.
                        var x = rect.midX - buttonWidth / 2
                        var y = rect.maxY + gap

                        // Horizontal clamp: keep within view width.
                        x = max(0, min(x, reportedWidth - buttonWidth))

                        // Vertical fallback: if below doesn't fit, place above.
                        if y + buttonHeight > reportedHeight {
                            y = rect.minY - buttonHeight - gap
                        }

                        selectionAnchor = CGPoint(x: x, y: y)
                        onSelectionChange(blockID, text)
                    } else {
                        selectionAnchor = nil
                        onSelectionChange(blockID, nil)
                    }
                }
            )
            .frame(height: reportedHeight)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Reply ↩ button, positioned at selection anchor.
            // Visible whenever this block has a pending native selection.
            if let anchor = selectionAnchor {
                Button {
                    onReply()
                    // Clear native NSTextView selection after Reply.
                    clearTrigger += 1
                    selectionAnchor = nil
                } label: {
                    HStack(spacing: 4) {
                        Text("Reply")
                            .font(.system(size: 11, weight: .medium))
                        Text("\u{21A9}")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.20, green: 0.20, blue: 0.20))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .offset(x: anchor.x, y: anchor.y)
            }
        }
        // Cross-block single-selection enforcement: when another block becomes
        // the active selection, clear this block's native selection and Reply button.
        // Using SwiftUI .onChange is more reliable than updateNSView coordination
        // because it fires at the SwiftUI level before the next layout pass.
        .onChange(of: activeSelectionBlockID) { _, newActive in
            if let newActive, newActive != blockID, selectionAnchor != nil {
                #if DEBUG
                print("[AnchoredFollowUp] clearing previous native selection block=\(blockID.source):\(blockID.index) newActiveBlock=\(newActive.source):\(newActive.index)")
                #endif
                selectionAnchor = nil
                clearTrigger += 1
            }
        }
    }
}

// MARK: - NSViewRepresentable

/// AppKit NSTextView wrapper that reports text selection changes and view height.
private struct SelectableTextViewRepresentable: NSViewRepresentable {

    let attributedString: AttributedString
    @Binding var reportedHeight: CGFloat
    @Binding var reportedWidth: CGFloat
    @Binding var clearTrigger: Int
    let onSelectionChange: (String?, NSRect?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.delegate = context.coordinator
        context.coordinator.textView = textView

        // Set content, preserving existing formatting from ExplanationTagParser.
        // Suppress the initial delegate callback from setAttributedString.
        context.coordinator.suppressNextDeselection = true
        let nsAttrStr = Self.buildNSAttributedString(from: attributedString)
        textView.textStorage?.setAttributedString(nsAttrStr)

        // Store the source AttributedString for change detection.
        context.coordinator.lastAttributedString = attributedString

        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        // Update content only when the source AttributedString actually changed.
        // Comparing source values avoids the bridging asymmetry that caused
        // spurious setAttributedString calls (and selection clearing) every
        // time updateNSView ran.
        if attributedString != context.coordinator.lastAttributedString {
            context.coordinator.lastAttributedString = attributedString
            context.coordinator.suppressNextDeselection = true
            let nsAttrStr = Self.buildNSAttributedString(from: attributedString)
            textView.textStorage?.setAttributedString(nsAttrStr)
        }

        // Handle clear trigger: deselect all text.
        if clearTrigger != context.coordinator.lastClearTrigger {
            context.coordinator.lastClearTrigger = clearTrigger
            context.coordinator.suppressNextDeselection = true
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }

        // Report dimensions after layout, deferred to avoid mutating state
        // during the SwiftUI view update pass.
        let currentHeight = reportedHeight
        let currentWidth = reportedWidth
        DispatchQueue.main.async {
            if let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
                let usedRect = layoutManager.usedRect(for: textContainer)
                let newHeight = ceil(usedRect.height)
                if abs(newHeight - currentHeight) > 1 {
                    reportedHeight = newHeight
                }
            }
            let newWidth = textView.bounds.width
            if abs(newWidth - currentWidth) > 1 {
                reportedWidth = newWidth
            }
        }
    }

    /// Build NSAttributedString from SwiftUI AttributedString, applying fallback
    /// font to any runs that lack a font attribute. Produces a stable result
    /// suitable for direct comparison or assignment to text storage.
    private static func buildNSAttributedString(from source: AttributedString) -> NSAttributedString {
        let bridged = NSAttributedString(source)
        let nsAttrStr = NSMutableAttributedString(attributedString: bridged)
        let defaultFont = NSFont.systemFont(ofSize: 13)
        let fullRange = NSRange(location: 0, length: nsAttrStr.length)
        nsAttrStr.enumerateAttribute(NSAttributedString.Key.font, in: fullRange, options: []) { value, range, _ in
            if value == nil {
                nsAttrStr.addAttribute(NSAttributedString.Key.font, value: defaultFont, range: range)
            }
        }
        return nsAttrStr
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let onSelectionChange: (String?, NSRect?) -> Void
        weak var textView: NSTextView?
        var lastClearTrigger: Int = 0

        /// Tracks the source AttributedString to avoid spurious content resets.
        var lastAttributedString: AttributedString?

        /// When true, the next deselection callback is suppressed (programmatic clear).
        var suppressNextDeselection: Bool = false

        init(onSelectionChange: @escaping (String?, NSRect?) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else {
                return
            }

            let range = textView.selectedRange()
            if range.length == 0 {
                if suppressNextDeselection {
                    #if DEBUG
                    print("[AnchoredFollowUp] native selection cleared (suppressed callback) range={\(range.location), \(range.length)}")
                    #endif
                    suppressNextDeselection = false
                    return
                }
                #if DEBUG
                print("[AnchoredFollowUp] native deselection callback range={\(range.location), \(range.length)}")
                #endif
                onSelectionChange(nil, nil)
                return
            }

            // Clear suppression on any genuine selection (non-zero length).
            suppressNextDeselection = false

            let nsString = textView.string as NSString
            let selectedText = nsString.substring(with: range)
            guard !selectedText.isEmpty else {
                onSelectionChange(nil, nil)
                return
            }

            #if DEBUG
            print("[AnchoredFollowUp] native selection range={\(range.location), \(range.length)} length=\(selectedText.count)")
            #endif

            // Compute selection geometry for Reply button positioning.
            if let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                onSelectionChange(selectedText, rect)
            } else {
                onSelectionChange(selectedText, nil)
            }
        }
    }
}

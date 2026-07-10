import AppKit
import SwiftUI

// MARK: - Public API
//
// IndicatorPanel owns the floating mic capsule that sits at the caret,
// matching the system dictation look: solid blue pill, white mic.
//
//   let panel = IndicatorPanel()
//   panel.show(at: CaretLocator.caretAnchor())
//   panel.update(state: .listening)
//   panel.update(state: .processing)
//   panel.hide()
//
// While shown, the panel polls `CaretLocator` at ~10 Hz and repositions.
// Polling stops on `hide()`. The panel never activates the app
// (`.nonactivatingPanel`, `canBecomeKey`/`canBecomeMain` == false).

/// Visual state of the caret mic indicator.
enum IndicatorState: Equatable, Sendable {
    /// Actively capturing — subtle pulse on the pill.
    case listening
    /// Final flush / commit in progress — quieter pill + spinner.
    case processing
}

/// Non-activating floating NSPanel hosting the macOS-dictation-style mic capsule.
@MainActor
final class IndicatorPanel {
    private let panel: IndicatorNSPanel
    private let hostingView: NSHostingView<IndicatorCapsuleView>
    private var model = IndicatorViewModel()
    private var pollTimer: Timer?
    private var isVisible = false

    /// Panel is larger than the painted pill so soft shadow isn't clipped.
    /// Visual pill ≈ 34×28 — chubby stadium, tight around the mic.
    private let panelSize = CGSize(width: 48, height: 44)
    private let caretGap: CGFloat = 8

    init() {
        panel = IndicatorNSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // shadow drawn in SwiftUI for tighter shape match
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = false

        hostingView = NSHostingView(rootView: IndicatorCapsuleView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        panel.contentView = hostingView
        panel.orderOut(nil)
    }

    /// Shows the indicator at `anchor` and starts ~10 Hz caret polling.
    func show(at anchor: CaretAnchor) {
        model.state = .listening
        hostingView.rootView = IndicatorCapsuleView(model: model)
        position(near: anchor)
        panel.orderFrontRegardless()
        isVisible = true
        startPolling()
    }

    /// Updates listening vs processing appearance.
    func update(state: IndicatorState) {
        model.state = state
        hostingView.rootView = IndicatorCapsuleView(model: model)
        if isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Hides the panel and stops caret polling.
    func hide() {
        stopPolling()
        isVisible = false
        panel.orderOut(nil)
    }

    var isShowing: Bool { isVisible }
}

// MARK: - Polling & placement

private extension IndicatorPanel {
    func startPolling() {
        stopPolling()
        // ~10 Hz; `.common` keeps polling alive during menu tracking in other apps.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollCaret()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func pollCaret() {
        guard isVisible else { return }
        let anchor = CaretLocator.caretAnchor()
        position(near: anchor)
    }

    func position(near anchor: CaretAnchor) {
        let target = anchor.rect
        let visible = screenVisibleFrame(containing: target)
        let size = panelSize

        // Prefer just to the right of the caret; flip left if clipped.
        var originX = target.maxX + caretGap
        if originX + size.width > visible.maxX - 4 {
            originX = target.minX - caretGap - size.width
        }
        originX = min(max(originX, visible.minX + 4), visible.maxX - size.width - 4)

        // Sit slightly below the caret midline (system dictation sits low).
        var originY = target.midY - size.height * 0.65
        originY = min(max(originY, visible.minY + 4), visible.maxY - size.height - 4)

        let frame = NSRect(origin: CGPoint(x: originX, y: originY), size: size)
        panel.setFrame(frame, display: true)
        hostingView.frame = NSRect(origin: .zero, size: size)
    }

    func screenVisibleFrame(containing rect: CGRect) -> CGRect {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main
        return screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
    }
}

// MARK: - Non-activating panel

private final class IndicatorNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI content

@MainActor
final class IndicatorViewModel {
    var state: IndicatorState = .listening
}

private struct IndicatorCapsuleView: View {
    let model: IndicatorViewModel

    var body: some View {
        IndicatorCapsuleContent(state: model.state)
    }
}

/// Solid blue pill + white mic — same silhouette as system dictation.
private struct IndicatorCapsuleContent: View {
    let state: IndicatorState

    @State private var pulse = false

    /// Chubby stadium (~1.2:1): flat mid-edges, true semicircle ends, tight mic pad.
    private let pillSize = CGSize(width: 34, height: 28)

    private var pillBlue: Color {
        Color(nsColor: .systemBlue)
    }

    var body: some View {
        ZStack {
            Capsule(style: .circular)
                .fill(pillBlue)
                .overlay {
                    // Soft top sheen — reads more like system chrome than flat paint.
                    Capsule(style: .circular)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.28),
                                    .white.opacity(0.04),
                                    .clear,
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                }
                .frame(width: pillSize.width, height: pillSize.height)
                .opacity(state == .processing ? 0.72 : (pulse ? 1.0 : 0.96))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .shadow(color: pillBlue.opacity(0.22), radius: 3, y: 1)

            switch state {
            case .listening:
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.monochrome)
            case .processing:
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(state == .listening && pulse ? 1.03 : 1.0)
        .onAppear {
            guard state == .listening else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: state) { _, newState in
            if newState == .listening {
                withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.15)) {
                    pulse = false
                }
            }
        }
    }
}

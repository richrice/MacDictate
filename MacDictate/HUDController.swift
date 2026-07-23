import AppKit
import Combine
import SwiftUI

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private struct HUDView: View {
    let phase: DictationPhase
    let audioRecorder: AudioRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Group {
                    switch phase {
                    case .recording:
                        Image(systemName: "mic.fill").foregroundStyle(.red)
                    case .preparing, .transcribing, .inserting:
                        ProgressView().controlSize(.small)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .cancelled:
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    case .idle:
                        Image(systemName: "waveform")
                    }
                }
                statusContent
            }
            inputDetails
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
    }

    @ViewBuilder
    private var statusContent: some View {
        if case let .recording(startedAt) = phase {
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                Text("Recording  \(elapsed, format: .number.precision(.fractionLength(1)))s")
                    .monospacedDigit()
            }
        } else {
            Text(phase.statusText).lineLimit(2)
        }
    }

    @ViewBuilder
    private var inputDetails: some View {
        switch phase {
        case .preparing:
            Text("Mic: \(audioRecorder.currentInputDeviceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .recording:
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                HStack(spacing: 8) {
                    Text("Mic: \(audioRecorder.currentInputDeviceName)")
                        .lineLimit(1)
                    let level = audioRecorder.inputLevel
                    ProgressView(value: Double(level))
                        .progressViewStyle(.linear)
                        .tint(level > 0.05 ? .green : .secondary)
                        .frame(width: 90)
                        .accessibilityLabel("Microphone input level")
                        .accessibilityValue("\(Int(level * 100)) percent")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

@MainActor
final class HUDController {
    private let panel: NSPanel
    private let stateMachine: DictationStateMachine
    private let settings: SettingsStore
    private let audioRecorder: AudioRecording
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    init(
        stateMachine: DictationStateMachine,
        settings: SettingsStore,
        audioRecorder: AudioRecording
    ) {
        self.stateMachine = stateMachine
        self.settings = settings
        self.audioRecorder = audioRecorder
        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.worksWhenModal = true
        self.panel = panel

        cancellable = stateMachine.$state.sink { [weak self] phase in
            MainActor.assumeIsolated { self?.render(phase) }
        }
    }

    private func render(_ phase: DictationPhase) {
        hideTask?.cancel()
        guard settings.showHUD, phase != .idle else {
            panel.orderOut(nil)
            return
        }
        panel.contentViewController = NSHostingController(
            rootView: HUDView(phase: phase, audioRecorder: audioRecorder)
        )
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        let fitting = panel.contentViewController?.view.fittingSize ?? NSSize(width: 300, height: 64)
        panel.setContentSize(NSSize(width: min(max(fitting.width, 190), 520), height: max(fitting.height, 52)))
        positionPanel()
        panel.orderFrontRegardless()

        let delay: UInt64?
        switch phase {
        case .completed, .cancelled: delay = 1_200_000_000
        case .failed: delay = 3_000_000_000
        default: delay = nil
        }
        if let delay {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        }
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.minY + 72
        )
        panel.setFrameOrigin(origin)
    }
}

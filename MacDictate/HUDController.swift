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
    var showsMuteNote: Bool = false

    var body: some View {
        Group {
            if case let .recording(startedAt) = phase {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                    let level = audioRecorder.inputLevel
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 10) {
                            Image(systemName: "mic.fill").foregroundStyle(.red)
                            Text("Recording  \(elapsed, format: .number.precision(.fractionLength(1)))s")
                                .monospacedDigit()
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            if showsMuteNote {
                                Text("System audio muted until your text is delivered")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 8) {
                                Text("Mic: \(audioRecorder.currentInputDeviceName)")
                                    .lineLimit(1)
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
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        phaseIcon
                        Text(phase.statusText).lineLimit(2)
                    }
                    staticDetails
                }
            }
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minWidth: 190, maxWidth: 520, minHeight: 52)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
    }

    @ViewBuilder
    private var phaseIcon: some View {
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

    @ViewBuilder
    private var staticDetails: some View {
        switch phase {
        case .preparing:
            Text("Mic: \(audioRecorder.currentInputDeviceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .failed:
            Text("Full details: Copy Last Error Details in the menu bar menu")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        default:
            EmptyView()
        }
    }
}

@MainActor
final class HUDController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let hostingController: NSHostingController<HUDView>
    private let stateMachine: DictationStateMachine
    private let settings: SettingsStore
    private let audioRecorder: AudioRecording
    private var cancellable: AnyCancellable?

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
        // The hosting controller is created once and only its rootView is swapped afterwards.
        // Replacing the contentViewController per phase re-entered window layout mid-display-cycle.
        hostingController = NSHostingController(
            rootView: HUDView(phase: .idle, audioRecorder: audioRecorder)
        )
        panel.contentViewController = hostingController
        self.panel = panel
        super.init()

        // SwiftUI owns the panel's size; we only recentre it once AppKit reports the new frame.
        panel.delegate = self
        cancellable = stateMachine.$state.sink { [weak self] phase in
            MainActor.assumeIsolated { self?.render(phase) }
        }
    }

    func windowDidResize(_ notification: Notification) {
        positionPanel()
    }

    private func render(_ phase: DictationPhase) {
        guard settings.showHUD, phase != .idle else {
            panel.orderOut(nil)
            return
        }
        var showMuteNote = false
        if case .recording = phase,
           settings.muteSystemAudioDuringDictation,
           !settings.hasSeenMuteNotice {
            settings.hasSeenMuteNotice = true
            showMuteNote = true
        }
        hostingController.rootView = HUDView(
            phase: phase,
            audioRecorder: audioRecorder,
            showsMuteNote: showMuteNote
        )
        positionPanel()
        panel.orderFrontRegardless()
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

import Foundation

enum DictationPhase: Equatable, Sendable {
    case idle
    case preparing
    case recording(startedAt: Date)
    case transcribing
    case inserting
    case completed(message: String)
    case cancelled(message: String?)
    case failed(message: String)

    var statusText: String {
        switch self {
        case .idle: "Ready"
        case .preparing: "Preparing microphone…"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        case .inserting: "Inserting text…"
        case let .completed(message): message
        case let .cancelled(message): message ?? "Cancelled"
        case let .failed(message): "Error: \(message)"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .transcribing, .inserting:
            true
        default:
            false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        default:
            false
        }
    }

    fileprivate var kind: Kind {
        switch self {
        case .idle: .idle
        case .preparing: .preparing
        case .recording: .recording
        case .transcribing: .transcribing
        case .inserting: .inserting
        case .completed: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    fileprivate enum Kind: Hashable {
        case idle, preparing, recording, transcribing, inserting, completed, cancelled, failed
    }
}

enum StateTransitionError: LocalizedError, Equatable {
    case invalid(from: String, to: String)

    var errorDescription: String? {
        switch self {
        case let .invalid(from, to):
            "Invalid dictation transition from \(from) to \(to)."
        }
    }
}

@MainActor
final class DictationStateMachine: ObservableObject {
    @Published private(set) var state: DictationPhase = .idle

    private static let validTransitions: [DictationPhase.Kind: Set<DictationPhase.Kind>] = [
        .idle: [.preparing],
        .preparing: [.recording, .cancelled, .failed],
        .recording: [.transcribing, .cancelled, .failed],
        .transcribing: [.inserting, .completed, .cancelled, .failed],
        .inserting: [.completed, .cancelled, .failed],
        .completed: [.idle],
        .cancelled: [.idle],
        .failed: [.idle]
    ]

    func transition(to newState: DictationPhase) throws {
        guard newState != state else {
            throw StateTransitionError.invalid(from: state.statusText, to: newState.statusText)
        }
        guard Self.validTransitions[state.kind, default: []].contains(newState.kind) else {
            throw StateTransitionError.invalid(from: state.statusText, to: newState.statusText)
        }
        state = newState
    }

    func resetAfterTerminalState() {
        switch state {
        case .completed, .cancelled, .failed:
            try? transition(to: .idle)
        default:
            break
        }
    }
}

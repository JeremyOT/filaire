import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOSSH
import Citadel

/// Represents an in-flight SSH connection attempt, owning its transport channel from creation
/// and coordinating cancellation, timeouts, atomic host-key decisions, and channel cleanup.
public final class SSHConnectionAttempt: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case pending
        case connected
        case validatingHostKey
        case authenticated
        case completed
        case failed(String)
        case cancelled
    }

    private let lock: NIOLockedValueBox<AttemptState>
    public let id: UUID

    private struct AttemptState {
        var state: State = .pending
        var channel: Channel? = nil
        var hostKeyContinuation: CheckedContinuation<Bool, Never>? = nil
        var onChannelCreatedCallbacks: [(Channel) -> Void] = []
        var cleanups: [() -> Void] = []
    }

    public init(id: UUID = UUID()) {
        self.id = id
        self.lock = NIOLockedValueBox(AttemptState())
    }

    public var isCancelled: Bool {
        lock.withLockedValue { $0.state == .cancelled }
    }

    public var isActive: Bool {
        lock.withLockedValue {
            switch $0.state {
            case .pending, .connected, .validatingHostKey, .authenticated:
                return true
            case .completed, .failed, .cancelled:
                return false
            }
        }
    }

    public var channel: Channel? {
        lock.withLockedValue { $0.channel }
    }

    /// Registers a callback to be invoked as soon as the transport channel is created.
    public func onChannelCreated(_ callback: @escaping @Sendable (Channel) -> Void) {
        let channelToCall: Channel? = lock.withLockedValue { state in
            if let ch = state.channel {
                return ch
            }
            state.onChannelCreatedCallbacks.append(callback)
            return nil
        }
        if let ch = channelToCall {
            callback(ch)
        }
    }

    /// Sets the transport channel when created.
    /// If the attempt was already cancelled or failed, closes the channel immediately.
    public func setChannel(_ channel: Channel) {
        let (shouldClose, callbacks) = lock.withLockedValue { state -> (Bool, [(Channel) -> Void]) in
            switch state.state {
            case .cancelled, .failed:
                return (true, [])
            default:
                state.channel = channel
                if state.state == .pending {
                    state.state = .connected
                }
                let cbs = state.onChannelCreatedCallbacks
                state.onChannelCreatedCallbacks.removeAll()
                return (false, cbs)
            }
        }

        if shouldClose {
            _ = channel.close(mode: .all)
            return
        }

        for cb in callbacks {
            cb(channel)
        }
    }

    public func pauseHandshakeTimeout() {
        lock.withLockedValue { state in
            if state.state == .connected {
                state.state = .validatingHostKey
            }
        }
    }

    public func resumeHandshakeTimeout(budget: TimeAmount = .seconds(10)) {
        lock.withLockedValue { state in
            if state.state == .validatingHostKey {
                state.state = .connected
            }
        }
    }

    /// Atomically validates that the attempt is still active and records the host-key approval.
    /// Returns true only if the attempt was in `.validatingHostKey` or `.connected` and is still active.
    /// If the attempt was cancelled or failed, returns false so the key is NOT saved.
    public func approveHostKey() -> Bool {
        lock.withLockedValue { state in
            guard state.state == .validatingHostKey || state.state == .connected else {
                return false
            }
            state.state = .connected
            state.hostKeyContinuation = nil
            return true
        }
    }

    /// Transitions attempt to succeeded/authenticated.
    public func succeed() {
        lock.withLockedValue { state in
            switch state.state {
            case .pending, .connected, .validatingHostKey:
                state.state = .authenticated
            default:
                break
            }
        }
    }

    /// Marks the attempt as completed normally after full session setup.
    public func complete() {
        let cleanups = lock.withLockedValue { state -> [() -> Void] in
            switch state.state {
            case .completed, .failed, .cancelled:
                return []
            default:
                state.state = .completed
                let cleanups = state.cleanups
                state.cleanups.removeAll()
                return cleanups
            }
        }
        for cleanup in cleanups {
            cleanup()
        }
    }

    /// Fails the attempt with an error, immediately closing any associated channel.
    public func fail(error: Error) {
        let (ch, cont, cleanups) = lock.withLockedValue { state -> (Channel?, CheckedContinuation<Bool, Never>?, [() -> Void]) in
            switch state.state {
            case .completed, .failed, .cancelled:
                return (nil, nil, [])
            default:
                state.state = .failed("\(error)")
                let ch = state.channel
                let c = state.hostKeyContinuation
                let cleanups = state.cleanups
                state.channel = nil
                state.hostKeyContinuation = nil
                state.cleanups.removeAll()
                return (ch, c, cleanups)
            }
        }
        _ = ch?.close(mode: .all)
        cont?.resume(returning: false)
        for cleanup in cleanups {
            cleanup()
        }
    }

    /// Cancels the attempt, immediately closing any associated channel.
    public func cancel() {
        let (ch, cont, cleanups) = lock.withLockedValue { state -> (Channel?, CheckedContinuation<Bool, Never>?, [() -> Void]) in
            switch state.state {
            case .completed, .failed, .cancelled:
                return (nil, nil, [])
            default:
                state.state = .cancelled
                let ch = state.channel
                let c = state.hostKeyContinuation
                let cleanups = state.cleanups
                state.channel = nil
                state.hostKeyContinuation = nil
                state.cleanups.removeAll()
                return (ch, c, cleanups)
            }
        }
        _ = ch?.close(mode: .all)
        cont?.resume(returning: false)
        for cleanup in cleanups {
            cleanup()
        }
    }

    public func registerHostKeyContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
        let shouldResumeFalse = lock.withLockedValue { state -> Bool in
            switch state.state {
            case .cancelled, .failed:
                return true
            default:
                state.hostKeyContinuation = continuation
                return false
            }
        }
        if shouldResumeFalse {
            continuation.resume(returning: false)
        }
    }

    public func registerCleanup(_ cleanup: @escaping () -> Void) {
        let shouldExecuteImmediately = lock.withLockedValue { state -> Bool in
            switch state.state {
            case .completed, .failed, .cancelled:
                return true
            default:
                state.cleanups.append(cleanup)
                return false
            }
        }
        if shouldExecuteImmediately {
            cleanup()
        }
    }

    public func onCleanup(_ cleanup: @escaping () -> Void) {
        registerCleanup(cleanup)
    }
}

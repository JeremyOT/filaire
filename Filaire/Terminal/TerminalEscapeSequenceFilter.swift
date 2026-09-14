import Foundation

/// Streaming escape sequence boundary filter.
/// Inspects incoming terminal byte streams before feeding them into SwiftTerm,
/// bounding retained OSC, APC, and DCS passthrough memory across arbitrarily many input chunks.
/// Discards oversized sequences before handlers run, rejects unsafe Sixel sequences before SwiftTerm's
/// decoder, correctly validates and preserves UTF-8 multibyte characters, normalizes standalone C1 controls,
/// and unwraps bounded tmux DCS passthrough wrappers.
public final class TerminalEscapeSequenceFilter: @unchecked Sendable {
    public enum SequenceType: Sendable {
        case osc
        case apc
        case dcs
    }

    private enum State {
        case ground
        case sawEsc
        case accumulatingDcsHeader
        case accumulating(type: SequenceType)
        case sawEscInAccumulating(type: SequenceType)
        case discarding(type: SequenceType)
        case sawEscInDiscarding(type: SequenceType)
    }

    public static let maxSinglePayloadSize: Int = 2 * 1024 * 1024
    public static let maxProtocolPrefixAllowance: Int = 1024
    public static let maxPayloadCapacity: Int = maxSinglePayloadSize + maxProtocolPrefixAllowance
    private static let maxTmuxNestingDepth: Int = 2

    private struct UTF8ScannerState {
        var expectedContinuations: UInt8 = 0
        var minContinuation: UInt8 = 0x80
        var maxContinuation: UInt8 = 0xBF

        mutating func reset() {
            expectedContinuations = 0
            minContinuation = 0x80
            maxContinuation = 0xBF
        }

        /// Feeds a byte into the incremental UTF-8 tracker.
        /// Returns `true` if the byte is a valid continuation byte of an in-progress UTF-8 character.
        /// Returns `false` if the byte is not a continuation byte. If an invalid continuation is encountered,
        /// resets the tracker and evaluates whether this byte starts a new multibyte sequence.
        mutating func processByte(_ byte: UInt8) -> Bool {
            if expectedContinuations > 0 {
                if byte >= minContinuation && byte <= maxContinuation {
                    expectedContinuations -= 1
                    minContinuation = 0x80
                    maxContinuation = 0xBF
                    return true
                }
                // Invalid continuation: reset and check if this byte begins a new sequence or control
                reset()
            }

            if byte >= 0xC2 && byte <= 0xDF {
                expectedContinuations = 1
                minContinuation = 0x80
                maxContinuation = 0xBF
            } else if byte == 0xE0 {
                expectedContinuations = 2
                minContinuation = 0xA0
                maxContinuation = 0xBF
            } else if (byte >= 0xE1 && byte <= 0xEC) || (byte >= 0xEE && byte <= 0xEF) {
                expectedContinuations = 2
                minContinuation = 0x80
                maxContinuation = 0xBF
            } else if byte == 0xED {
                expectedContinuations = 2
                minContinuation = 0x80
                maxContinuation = 0x9F
            } else if byte == 0xF0 {
                expectedContinuations = 3
                minContinuation = 0x90
                maxContinuation = 0xBF
            } else if byte >= 0xF1 && byte <= 0xF3 {
                expectedContinuations = 3
                minContinuation = 0x80
                maxContinuation = 0xBF
            } else if byte == 0xF4 {
                expectedContinuations = 3
                minContinuation = 0x80
                maxContinuation = 0x8F
            }
            return false
        }
    }

    private let lock = NSLock()
    private var state: State = .ground
    private var utf8Scanner = UTF8ScannerState()
    private var accumulatedBuffer: [UInt8] = []
    private var dcsIntermediates: [UInt8] = []
    private var discardedBytesCount: Int = 0

    public init() {}

    /// Current retained bytes waiting for sequence termination or pass-through.
    public var retainedBufferBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return accumulatedBuffer.count
    }

    /// Resets the filter state, UTF-8 scanner, and frees accumulated buffers.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        state = .ground
        utf8Scanner.reset()
        accumulatedBuffer.removeAll(keepingCapacity: false)
        dcsIntermediates.removeAll(keepingCapacity: false)
        discardedBytesCount = 0
    }

    /// Filters incoming byte slice and delivers safe output chunks to the provided consumer.
    public func filter(bytes: ArraySlice<UInt8>, deliver: (ArraySlice<UInt8>) -> Void) {
        lock.lock()
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)

        processChunk(bytes: bytes, nestingDepth: 0, output: &output)

        lock.unlock()

        if !output.isEmpty {
            deliver(output[...])
        }
    }

    private func processChunk(bytes: ArraySlice<UInt8>, nestingDepth: Int, output: inout [UInt8]) {
        var i = bytes.startIndex
        let endIndex = bytes.endIndex

        while i < endIndex {
            let byte = bytes[i]
            let isContinuation = utf8Scanner.processByte(byte)

            switch state {
            case .ground:
                if isContinuation {
                    // Continuation bytes are never control codes; pass through unchanged
                    output.append(byte)
                } else if byte == 0x1B { // ESC
                    state = .sawEsc
                } else if byte == 0x9D { // Standalone C1 OSC: normalize to ESC ]
                    state = .accumulating(type: .osc)
                    accumulatedBuffer.removeAll(keepingCapacity: true)
                    accumulatedBuffer.append(contentsOf: [0x1B, 0x5D])
                } else if byte == 0x9F { // Standalone C1 APC: normalize to ESC _
                    state = .accumulating(type: .apc)
                    accumulatedBuffer.removeAll(keepingCapacity: true)
                    accumulatedBuffer.append(contentsOf: [0x1B, 0x5F])
                } else if byte == 0x90 { // Standalone C1 DCS: normalize to ESC P
                    state = .accumulatingDcsHeader
                    accumulatedBuffer.removeAll(keepingCapacity: true)
                    accumulatedBuffer.append(contentsOf: [0x1B, 0x50])
                    dcsIntermediates.removeAll(keepingCapacity: true)
                } else {
                    output.append(byte)
                }

            case .sawEsc:
                if byte == UInt8(ascii: "]") { // OSC: ESC ]
                    state = .accumulating(type: .osc)
                    accumulatedBuffer.removeAll(keepingCapacity: true)
                    accumulatedBuffer.append(contentsOf: [0x1B, 0x5D])
                } else if byte == UInt8(ascii: "_") { // APC: ESC _
                    state = .accumulating(type: .apc)
                    accumulatedBuffer.removeAll(keepingCapacity: true)
                    accumulatedBuffer.append(contentsOf: [0x1B, 0x5F])
                } else if byte == UInt8(ascii: "P") { // DCS: ESC P
                    state = .accumulatingDcsHeader
                    accumulatedBuffer.removeAll(keepingCapacity: true)
                    accumulatedBuffer.append(contentsOf: [0x1B, 0x50])
                    dcsIntermediates.removeAll(keepingCapacity: true)
                } else if byte == 0x1B { // Consecutive ESC
                    output.append(0x1B)
                    state = .sawEsc
                } else {
                    // Non-string ESC sequence (e.g. CSI ESC [, RIS ESC c): forward ESC and byte
                    output.append(0x1B)
                    output.append(byte)
                    state = .ground
                }

            case .accumulatingDcsHeader:
                if !isContinuation && (byte == 0x07 || byte == 0x9C || byte == 0x1B) {
                    // Interruption or terminator before header completed
                    if byte == 0x1B {
                        state = .sawEscInAccumulating(type: .dcs)
                    } else if byte == 0x9C { // C1 ST
                        completeSequence(type: .dcs, terminator: [0x1B, 0x5C], nestingDepth: nestingDepth, output: &output)
                    } else {
                        // BEL does NOT terminate DCS! Treat as header data or append
                        appendToAccumulated(byte: byte, type: .dcs)
                    }
                } else if byte >= 0x20 && byte <= 0x2F {
                    // Intermediate byte (collect)
                    dcsIntermediates.append(byte)
                    appendToAccumulated(byte: byte, type: .dcs)
                } else if byte >= 0x30 && byte <= 0x3F {
                    // Parameter byte (0-9, ;, :, etc.)
                    appendToAccumulated(byte: byte, type: .dcs)
                } else if byte >= 0x40 && byte <= 0x7E {
                    // Final byte of DCS header!
                    // Sixel check: SwiftTerm dispatches to SixelDcsHandler when intermediates (collect) is empty and final byte is 'q' (0x71).
                    if dcsIntermediates.isEmpty && byte == 0x71 {
                        // Reject Sixel sequence to prevent downstream integer overflow / memory denial of service.
                        accumulatedBuffer.removeAll(keepingCapacity: false)
                        discardedBytesCount = 0
                        state = .discarding(type: .dcs)
                    } else {
                        // Safe DCS sequence (e.g. DECRQSS with intermediate '$' or tmux passthrough)
                        appendToAccumulated(byte: byte, type: .dcs)
                        if case .discarding = state {
                            // Capacity exceeded on header append
                        } else {
                            state = .accumulating(type: .dcs)
                        }
                    }
                } else {
                    // High byte or unexpected byte in header
                    appendToAccumulated(byte: byte, type: .dcs)
                }

            case .accumulating(let type):
                if !isContinuation && (byte == 0x07 || byte == 0x9C || byte == 0x18 || byte == 0x1A) {
                    // Sequence termination or cancellation
                    switch type {
                    case .osc, .apc:
                        if byte == 0x07 { // BEL
                            completeSequence(type: type, terminator: [0x07], nestingDepth: nestingDepth, output: &output)
                        } else if byte == 0x9C { // C1 ST: normalize to ESC \
                            completeSequence(type: type, terminator: [0x1B, 0x5C], nestingDepth: nestingDepth, output: &output)
                        } else {
                            // CAN (0x18) or SUB (0x1A): drop cancelled buffered frame immediately
                            accumulatedBuffer.removeAll(keepingCapacity: false)
                            state = .ground
                        }
                    case .dcs:
                        if byte == 0x9C { // C1 ST terminates DCS: normalize to ESC \
                            completeSequence(type: .dcs, terminator: [0x1B, 0x5C], nestingDepth: nestingDepth, output: &output)
                        } else {
                            // In SwiftTerm, BEL, CAN, SUB inside DCS passthrough are data (dcsPut)
                            appendToAccumulated(byte: byte, type: type)
                        }
                    }
                } else if byte == 0x1B {
                    state = .sawEscInAccumulating(type: type)
                } else {
                    appendToAccumulated(byte: byte, type: type)
                }

            case .sawEscInAccumulating(let type):
                if byte == UInt8(ascii: "\\") { // ST: ESC \
                    completeSequence(type: type, terminator: [0x1B, 0x5C], nestingDepth: nestingDepth, output: &output)
                } else if byte == 0x1B { // Consecutive ESC inside accumulating (e.g. doubled ESC in tmux DCS)
                    appendToAccumulated(byte: 0x1B, type: type)
                    appendToAccumulated(byte: 0x1B, type: type)
                    if case .discarding = state {
                        // Capacity exceeded on append
                    } else {
                        state = .accumulating(type: type)
                    }
                } else {
                    // ESC followed by non-backslash inside an accumulating sequence.
                    // This aborts the current unfinished sequence and begins a new sequence or ground text.
                    accumulatedBuffer.removeAll(keepingCapacity: false)
                    state = .ground
                    // Reprocess ESC then the current byte from ground
                    reprocessByteFromGround(0x1B, output: &output)
                    reprocessByteFromGround(byte, output: &output)
                }

            case .discarding(let type):
                if !isContinuation && (byte == 0x07 || byte == 0x9C || byte == 0x18 || byte == 0x1A) {
                    switch type {
                    case .osc, .apc:
                        // BEL, C1 ST, CAN, SUB terminate discarded OSC/APC
                        discardedBytesCount = 0
                        state = .ground
                    case .dcs:
                        if byte == 0x9C { // C1 ST terminates discarded DCS
                            discardedBytesCount = 0
                            state = .ground
                        } else {
                            // BEL, CAN, SUB do NOT terminate DCS in SwiftTerm; stay in discard
                            discardedBytesCount &+= 1
                        }
                    }
                } else if byte == 0x1B {
                    state = .sawEscInDiscarding(type: type)
                } else {
                    discardedBytesCount &+= 1
                }

            case .sawEscInDiscarding(let type):
                if byte == UInt8(ascii: "\\") { // ST: ESC \
                    discardedBytesCount = 0
                    state = .ground
                } else if byte == 0x1B {
                    discardedBytesCount &+= 2
                    state = .discarding(type: type)
                } else {
                    // ESC followed by non-backslash aborts the discarded frame and starts a new sequence
                    discardedBytesCount = 0
                    state = .ground
                    reprocessByteFromGround(0x1B, output: &output)
                    reprocessByteFromGround(byte, output: &output)
                }
            }

            i += 1
        }
    }

    private func appendToAccumulated(byte: UInt8, type: SequenceType) {
        let (projected, overflow) = accumulatedBuffer.count.addingReportingOverflow(1)
        if overflow || projected > Self.maxPayloadCapacity {
            accumulatedBuffer.removeAll(keepingCapacity: false)
            discardedBytesCount = projected
            state = .discarding(type: type)
        } else {
            accumulatedBuffer.append(byte)
        }
    }

    private func completeSequence(
        type: SequenceType,
        terminator: [UInt8],
        nestingDepth: Int,
        output: inout [UInt8]
    ) {
        let (projected, overflow) = accumulatedBuffer.count.addingReportingOverflow(terminator.count)
        if overflow || projected > Self.maxPayloadCapacity {
            accumulatedBuffer.removeAll(keepingCapacity: false)
            discardedBytesCount = 0
            state = .ground
            return
        }

        accumulatedBuffer.append(contentsOf: terminator)

        // Check if this is a complete tmux DCS passthrough wrapper: \ePtmux;...\e\
        if type == .dcs && isTmuxPassthrough(accumulatedBuffer) {
            let bufferToUnwrap = accumulatedBuffer
            accumulatedBuffer.removeAll(keepingCapacity: false)
            state = .ground

            if nestingDepth < Self.maxTmuxNestingDepth {
                unwrapTmuxPassthrough(buffer: bufferToUnwrap, nestingDepth: nestingDepth + 1, output: &output)
            }
            return
        }

        output.append(contentsOf: accumulatedBuffer)
        accumulatedBuffer.removeAll(keepingCapacity: false)
        state = .ground
    }

    private func isTmuxPassthrough(_ buffer: [UInt8]) -> Bool {
        // Minimum: \ePtmux;\e\ (9 bytes)
        let prefix: [UInt8] = [0x1B, 0x50, UInt8(ascii: "t"), UInt8(ascii: "m"), UInt8(ascii: "u"), UInt8(ascii: "x"), UInt8(ascii: ";")]
        guard buffer.count >= 9 else { return false }
        guard buffer.starts(with: prefix) else { return false }
        guard buffer[buffer.count - 2] == 0x1B && buffer[buffer.count - 1] == 0x5C else { return false }
        return true
    }

    private func unwrapTmuxPassthrough(buffer: [UInt8], nestingDepth: Int, output: inout [UInt8]) {
        // Strip outer "\ePtmux;" (7 bytes) and trailing "\e\" (2 bytes)
        let innerSlice = buffer[7 ..< (buffer.count - 2)]
        var unescaped = [UInt8]()
        unescaped.reserveCapacity(innerSlice.count)

        var idx = innerSlice.startIndex
        let endIdx = innerSlice.endIndex
        while idx < endIdx {
            let b = innerSlice[idx]
            if b == 0x1B && idx + 1 < endIdx && innerSlice[idx + 1] == 0x1B {
                unescaped.append(0x1B)
                idx += 2
            } else {
                unescaped.append(b)
                idx += 1
            }
        }

        // Validate and filter unescaped inner payload with incremented nesting depth
        processChunk(bytes: unescaped[...], nestingDepth: nestingDepth, output: &output)
    }

    private func reprocessByteFromGround(_ byte: UInt8, output: inout [UInt8]) {
        let isContinuation = utf8Scanner.processByte(byte)
        if isContinuation {
            output.append(byte)
        } else if byte == 0x1B {
            state = .sawEsc
        } else if byte == 0x9D {
            state = .accumulating(type: .osc)
            accumulatedBuffer.removeAll(keepingCapacity: true)
            accumulatedBuffer.append(contentsOf: [0x1B, 0x5D])
        } else if byte == 0x9F {
            state = .accumulating(type: .apc)
            accumulatedBuffer.removeAll(keepingCapacity: true)
            accumulatedBuffer.append(contentsOf: [0x1B, 0x5F])
        } else if byte == 0x90 {
            state = .accumulatingDcsHeader
            accumulatedBuffer.removeAll(keepingCapacity: true)
            accumulatedBuffer.append(contentsOf: [0x1B, 0x50])
            dcsIntermediates.removeAll(keepingCapacity: true)
        } else {
            output.append(byte)
        }
    }
}

import Foundation

/// Buffers and coalesces high-frequency incoming byte streams from SSH,
/// delivering aggregated chunks to the main thread with end-to-end backpressure,
/// watermarks, generation tagging, and debug metrics.
public final class OutputCoalescer: @unchecked Sendable {
    public static let defaultHighWatermark: Int = 1024 * 1024       // 1 MiB
    public static let defaultLowWatermark: Int = 512 * 1024         // 512 KiB
    public static let defaultMaxBurstChunkSize: Int = 128 * 1024    // 128 KiB max per delivery

    public struct Metrics: Sendable, Equatable {
        public var queuedBytes: Int = 0
        public var peakQueuedBytes: Int = 0
        public var inFlightDeliveryBytes: Int = 0
        public var totalDeliveredBytes: Int = 0
        public var deliveryCount: Int = 0
        public var totalDeliveryDuration: TimeInterval = 0
        public var isBackpressureActive: Bool = false
        public var backpressureTriggerCount: Int = 0

        public var totalPendingBytes: Int {
            queuedBytes + inFlightDeliveryBytes
        }
    }

    private let lock = NSLock()
    private var chunks: [[UInt8]] = []
    private var readChunkIndex = 0
    private var readChunkOffset = 0
    private var queuedBytes = 0
    private var inFlightDeliveryBytes = 0
    private var isFlushScheduled = false
    private var generation: Int = 0
    private var isBackpressureActive = false

    private let highWatermark: Int
    private let lowWatermark: Int
    private let maxBurstChunkSize: Int
    private let onFlush: @Sendable ([UInt8]) -> Void
    private let onBackpressure: (@Sendable (Bool) -> Void)?

    private var _metrics = Metrics()

    public var metrics: Metrics {
        lock.lock()
        defer { lock.unlock() }
        var m = _metrics
        m.queuedBytes = queuedBytes
        m.inFlightDeliveryBytes = inFlightDeliveryBytes
        m.isBackpressureActive = isBackpressureActive
        return m
    }

    public var currentGeneration: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    public var totalPendingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedBytes + inFlightDeliveryBytes
    }

    public init(
        highWatermark: Int = defaultHighWatermark,
        lowWatermark: Int = defaultLowWatermark,
        maxBurstChunkSize: Int = defaultMaxBurstChunkSize,
        onFlush: @escaping @Sendable ([UInt8]) -> Void,
        onBackpressure: (@Sendable (Bool) -> Void)? = nil
    ) {
        self.highWatermark = highWatermark
        self.lowWatermark = lowWatermark
        self.maxBurstChunkSize = maxBurstChunkSize
        self.onFlush = onFlush
        self.onBackpressure = onBackpressure
    }

    /// Appends incoming bytes to the coalescing buffer and schedules a main-thread flush if not already pending.
    /// If generation is provided, chunks from older generations are rejected.
    public func append(_ bytes: [UInt8], generation: Int? = nil) {
        guard !bytes.isEmpty else { return }

        lock.lock()
        if let gen = generation, gen != self.generation {
            lock.unlock()
            return
        }

        chunks.append(bytes)
        queuedBytes += bytes.count
        let totalPending = queuedBytes + inFlightDeliveryBytes
        if totalPending > _metrics.peakQueuedBytes {
            _metrics.peakQueuedBytes = totalPending
        }

        var backpressureNotice: Bool? = nil
        if !isBackpressureActive && totalPending >= highWatermark {
            isBackpressureActive = true
            _metrics.isBackpressureActive = true
            _metrics.backpressureTriggerCount += 1
            backpressureNotice = true
        }

        let shouldSchedule = !isFlushScheduled
        isFlushScheduled = true
        let currentGen = self.generation
        lock.unlock()

        if let notice = backpressureNotice {
            onBackpressure?(notice)
        }

        if shouldSchedule {
            scheduleFlush(generation: currentGen)
        }
    }

    /// Ensures any remaining bytes are delivered on the next main-queue turn, preserving order
    public func flushImmediately() {
        lock.lock()
        let shouldSchedule = !isFlushScheduled && queuedBytes > 0
        if shouldSchedule {
            isFlushScheduled = true
        }
        let currentGen = self.generation
        lock.unlock()

        if shouldSchedule {
            scheduleFlush(generation: currentGen)
        }
    }

    /// Releases oversized reusable storage after bursts or under memory pressure
    public func releaseStorage() {
        lock.lock()
        defer { lock.unlock() }
        if readChunkIndex > 0 {
            chunks.removeFirst(readChunkIndex)
            readChunkIndex = 0
        }
        chunks = Array(chunks) // drops overallocated capacity
    }

    /// Clears any pending bytes without emitting and unpauses any active backpressure
    public func reset() {
        lock.lock()
        generation += 1
        chunks.removeAll(keepingCapacity: false)
        readChunkIndex = 0
        readChunkOffset = 0
        queuedBytes = 0
        inFlightDeliveryBytes = 0
        isFlushScheduled = false

        var backpressureNotice: Bool? = nil
        if isBackpressureActive {
            isBackpressureActive = false
            _metrics.isBackpressureActive = false
            backpressureNotice = false
        }
        lock.unlock()

        if let notice = backpressureNotice {
            onBackpressure?(notice)
        }
    }

    private func scheduleFlush(generation currentGen: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.deliverNextSlice(generation: currentGen)
        }
    }

    /// Delivers up to maxBurstChunkSize bytes from the front of the chunk queue, rescheduling while data remains
    private func deliverNextSlice(generation currentGen: Int) {
        lock.lock()
        guard currentGen == self.generation else {
            lock.unlock()
            return
        }

        if queuedBytes == 0 {
            isFlushScheduled = false
            lock.unlock()
            return
        }

        var slice: [UInt8] = []
        slice.reserveCapacity(min(queuedBytes, maxBurstChunkSize))
        var remainingToTake = maxBurstChunkSize

        while readChunkIndex < chunks.count && remainingToTake > 0 {
            let currentChunk = chunks[readChunkIndex]
            let availableInChunk = currentChunk.count - readChunkOffset
            let takeFromChunk = min(availableInChunk, remainingToTake)
            slice.append(contentsOf: currentChunk[readChunkOffset..<(readChunkOffset + takeFromChunk)])
            readChunkOffset += takeFromChunk
            remainingToTake -= takeFromChunk
            queuedBytes -= takeFromChunk

            if readChunkOffset >= currentChunk.count {
                readChunkIndex += 1
                readChunkOffset = 0
            }
        }

        if readChunkIndex >= chunks.count {
            chunks.removeAll(keepingCapacity: false)
            readChunkIndex = 0
            readChunkOffset = 0
        } else if readChunkIndex > 64 && readChunkIndex > chunks.count / 2 {
            chunks.removeFirst(readChunkIndex)
            readChunkIndex = 0
        }

        inFlightDeliveryBytes = slice.count
        _metrics.queuedBytes = queuedBytes
        _metrics.inFlightDeliveryBytes = inFlightDeliveryBytes

        var backpressureNotice: Bool? = nil
        let totalPending = queuedBytes + inFlightDeliveryBytes
        if isBackpressureActive && totalPending <= lowWatermark {
            isBackpressureActive = false
            _metrics.isBackpressureActive = false
            backpressureNotice = false
        }

        let hasMore = queuedBytes > 0
        if !hasMore {
            isFlushScheduled = false
        }
        lock.unlock()

        if let notice = backpressureNotice {
            onBackpressure?(notice)
        }

        if !slice.isEmpty {
            let startTime = ContinuousClock.now
            onFlush(slice)
            let elapsed = ContinuousClock.now - startTime
            let durationSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18

            lock.lock()
            if currentGen == self.generation {
                inFlightDeliveryBytes = 0
                _metrics.inFlightDeliveryBytes = 0
                _metrics.totalDeliveredBytes += slice.count
                _metrics.deliveryCount += 1
                _metrics.totalDeliveryDuration += durationSeconds

                if isBackpressureActive && queuedBytes <= lowWatermark {
                    isBackpressureActive = false
                    _metrics.isBackpressureActive = false
                    backpressureNotice = false
                } else {
                    backpressureNotice = nil
                }
            } else {
                backpressureNotice = nil
            }
            lock.unlock()

            if let notice = backpressureNotice {
                onBackpressure?(notice)
            }
        }

        if hasMore {
            scheduleFlush(generation: currentGen)
        }
    }
}

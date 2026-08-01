import Foundation

/// Where the time goes between a byte arriving and a pixel changing.
///
/// Added because two confident guesses about a 16x slowdown were both wrong -
/// an eagerly-built accessibility projection, then scrollback eviction. Neither
/// was the cost. Guessing at a pipeline is how you end up optimising the part
/// that was already fast.
///
/// Counters are plain and unsynchronised: the terminal consumes on one thread
/// and the view applies on the main thread, and a lost increment does not
/// change a conclusion drawn from ratios.
public enum Perf {
    nonisolated(unsafe) public static var consumeCalls = 0
    nonisolated(unsafe) public static var consumeBytes = 0
    nonisolated(unsafe) public static var consumeNanos: UInt64 = 0
    nonisolated(unsafe) public static var snapshotCalls = 0
    nonisolated(unsafe) public static var snapshotNanos: UInt64 = 0
    nonisolated(unsafe) public static var applyCalls = 0
    nonisolated(unsafe) public static var applyNanos: UInt64 = 0
    nonisolated(unsafe) public static var opCalls = 0
    nonisolated(unsafe) public static var renderCalls = 0
    nonisolated(unsafe) public static var renderNanos: UInt64 = 0

    @inline(__always)
    public static func time(_ nanos: inout UInt64, _ body: () -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        nanos &+= DispatchTime.now().uptimeNanoseconds &- start
    }

    public static func reset() {
        consumeCalls = 0; consumeBytes = 0; consumeNanos = 0
        snapshotCalls = 0; snapshotNanos = 0
        applyCalls = 0; applyNanos = 0
        opCalls = 0
        renderCalls = 0; renderNanos = 0
    }

    private static func ms(_ nanos: UInt64) -> String {
        String(format: "%.0fms", Double(nanos) / 1_000_000)
    }

    /// Parser throughput. `time cat` mostly measures how fast the pty accepts
    /// bytes, not how fast the terminal draws them, so the honest number is how
    /// much the engine consumed per second of consuming.
    public static var megabytesPerSecond: Double {
        guard consumeNanos > 0 else { return 0 }
        return Double(consumeBytes) / 1_048_576 / (Double(consumeNanos) / 1_000_000_000)
    }

    public static func report() -> String {
        String(format: "%.1fMB/s | ", megabytesPerSecond)
            + "consume=\(consumeCalls) calls \(consumeBytes / 1024)KB \(ms(consumeNanos)) | "
            + "snapshot=\(snapshotCalls) \(ms(snapshotNanos)) | "
            + "ops=\(opCalls) | "
            + "apply=\(applyCalls) \(ms(applyNanos)) | "
            + "render=\(renderCalls) \(ms(renderNanos))"
    }
}

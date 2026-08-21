// Live tunnel performance — passive throughput plus a latency probe.
//
// "Speed" here is deliberately passive: the rate of change of ppp0's
// byte counters, i.e. what is actually crossing the tunnel right now.
// It is not a speed test. An active one would burn the very bandwidth
// it claims to measure, and would have to load an internal host we
// have no business hammering once a minute. The trade-off is that an
// idle tunnel reads 0 B/s rather than showing link capacity — which is
// why the UI labels these "Down"/"Up" (traffic) and not "Speed".
//
// Latency is a single ICMP echo to the far end of the tunnel, so the
// number describes the VPN link rather than the user's internet
// connection.

import Darwin
import Foundation
import SwiftUI

/// One sample of tunnel performance, as rendered by the connect window
/// and the menu bar.
struct LinkMetrics: Equatable, Sendable {
    var downBytesPerSecond: Double
    var upBytesPerSecond: Double
    /// nil when the probe target never answered. Rendered as "—", not
    /// as zero — a zero would read as "instant".
    var latencyMilliseconds: Double?
    var sampledAt: Date

    // MARK: - Formatting

    // Both formatters live on the model rather than in the views so
    // the window and the menu bar can't drift into showing the same
    // sample two different ways. Both take an optional and render
    // `unavailable` for nil, so a UI that has no sample yet shows a
    // placeholder in place rather than omitting the readout — a row
    // that appears a second late shoves everything under it down.

    /// Shown wherever there is no number to show: no sample yet, or a
    /// probe target that never answered.
    static let unavailable = "—"

    /// Figure and unit separately, so a view can give the number the
    /// weight and the unit the quiet — "1,2" at 20pt beside a "MB/s"
    /// at caption size reads as one measurement, where the same string
    /// set solid reads as a label.
    ///
    /// `unit` is empty when there's nothing to qualify (no sample yet).
    static func rateParts(_ bytesPerSecond: Double?) -> (value: String, unit: String) {
        guard let bytesPerSecond else { return (unavailable, "") }
        let clamped = max(0, bytesPerSecond)
        let formatted = rateFormatter.string(fromByteCount: Int64(clamped.rounded()))
        // ByteCountFormatter yields "<figure> <unit>". Split from the
        // right so a locale that groups with spaces keeps its grouping
        // in the figure, and fall back to the whole string as the
        // figure if some locale ever hands back no space at all.
        guard let separator = formatted.lastIndex(of: " ") else { return (formatted, "/s") }
        return (String(formatted[formatted.startIndex..<separator]),
                String(formatted[formatted.index(after: separator)...]) + "/s")
    }

    static func latencyParts(_ milliseconds: Double?) -> (value: String, unit: String) {
        guard let ms = milliseconds else { return (unavailable, "") }
        // Sub-10ms is a same-datacentre gateway; rounding it to a whole
        // millisecond throws away the only digit that varies.
        let figure = ms < 10 ? String(format: "%.1f", ms) : "\(Int(ms.rounded()))"
        return (figure, "ms")
    }

    // The joined forms, for the menu bar — where everything has to be
    // one concatenated Text. Built from the parts above so there's a
    // single formatting path.

    static func rateText(_ bytesPerSecond: Double?) -> String {
        joined(rateParts(bytesPerSecond))
    }

    static func latencyText(_ milliseconds: Double?) -> String {
        joined(latencyParts(milliseconds))
    }

    private static func joined(_ parts: (value: String, unit: String)) -> String {
        parts.unit.isEmpty ? parts.value : "\(parts.value) \(parts.unit)"
    }

    // MARK: - Latency grading

    /// How good the round-trip is, in the app's existing severity
    /// vocabulary rather than a parallel one of its own — so the tile,
    /// the menu row and the status dot all mean the same thing by the
    /// same colour. nil when there's nothing measured to grade.
    ///
    /// The thresholds are judgement calls, not measurements: tuned for
    /// an internal corporate gateway, where a couple of dozen
    /// milliseconds is a healthy link and anything past a sixth of a
    /// second is felt as lag in an interactive session.
    static func latencyIndicator(_ milliseconds: Double?) -> ConnectionState.Indicator? {
        guard let ms = milliseconds else { return nil }
        if ms < goodBelowMilliseconds { return .ok }
        if ms < fairBelowMilliseconds { return .warn }
        return .bad
    }

    private static let goodBelowMilliseconds: Double = 60
    private static let fairBelowMilliseconds: Double = 150

    /// Decimal (SI) counting, because every other place the user will
    /// compare this number against — their ISP plan, a browser's
    /// download readout — quotes megabytes of 1000.
    ///
    /// `isAdaptive = false` keeps one decimal at KB scale, where the
    /// adaptive default collapses 1.2 KB/s and 1.9 KB/s to the same
    /// "1 KB/s"; `allowsNonnumericFormatting = false` turns an idle
    /// tunnel's "Zero bytes/s" into "0 bytes/s".
    private static let rateFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.isAdaptive = false
        f.allowsNonnumericFormatting = false
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return f
    }()
}

/// The rolling window of samples for the current connection.
///
/// Published separately from `ConnectionManager` on purpose. A sample
/// lands once a second for the whole life of a connection, and putting
/// it on the manager meant every view observing the *connection* was
/// invalidated at 1 Hz — including the menu-bar label, whose status item
/// is always present and re-rendered even with the menu and the window
/// both closed and nothing on screen consuming the numbers. Only the
/// two views that actually draw metrics observe this.
@MainActor
final class LinkMetricsStore: ObservableObject {
    @Published private(set) var history: [LinkMetrics] = []

    /// One minute at one sample a second — as much past as the
    /// sparklines draw, and no more.
    private static let capacity = 60

    var latest: LinkMetrics? { history.last }

    func append(_ sample: LinkMetrics) {
        history.append(sample)
        if history.count > Self.capacity {
            history.removeFirst(history.count - Self.capacity)
        }
    }

    /// Emptied when the tunnel goes away, so a reconnect starts from a
    /// blank graph rather than splicing the dead tunnel's samples onto
    /// the new one's.
    func clear() {
        history.removeAll()
    }
}

/// Cumulative byte counters for one network interface, read straight
/// from the kernel.
enum InterfaceCounters {

    struct Sample: Sendable {
        /// 32-bit, because that's what `if_data` carries — see
        /// `delta(from:)` for what that costs us.
        var inBytes: UInt32
        var outBytes: UInt32
        var at: Date
    }

    /// Reads `iface`'s counters, or nil if the interface is absent.
    ///
    /// This one goes through getifaddrs(3) rather than shelling out,
    /// which is the opposite call from `NetworkConfig.interfaceIPv4`
    /// right next door — and for the opposite reason: this runs once a
    /// second for the whole life of a connection, so a process per tick
    /// would cost far more than the pointer walk. The numbers are
    /// identical either way; `netstat -ib`'s `<Link#N>` row is this
    /// same `if_data`.
    static func read(_ iface: String) -> Sample? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }

        var entry: UnsafeMutablePointer<ifaddrs>? = head
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            // An interface appears once per address family, but only
            // the AF_LINK entry hangs an `if_data` off ifa_data — the
            // AF_INET/AF_INET6 entries point at something else, so
            // reading them as if_data would return garbage.
            guard let name = current.pointee.ifa_name,
                  String(cString: name) == iface,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            return Sample(inBytes: stats.ifi_ibytes, outBytes: stats.ifi_obytes, at: Date())
        }
        return nil
    }
}

extension InterfaceCounters.Sample {
    /// 1 Gbit/s. An openfortivpn tunnel on a laptop doesn't come near
    /// this — and the bound has to stay well under the 4 GiB counter
    /// wrap for the plausibility check below to mean anything at all.
    private static let maxPlausibleBytesPerSecond: Double = 125_000_000

    /// Longest gap we will still compute a rate from. `Task.sleep` runs
    /// on a continuous clock, so a system sleep resumes the poll loop
    /// with a gap of minutes; over that long the counters may have
    /// wrapped more than once and no arithmetic recovers the truth. The
    /// cap is also what keeps `ceiling` below the wrap — 10 s at 1 Gbit/s
    /// is 1.25 GB, comfortably under 4 GiB.
    private static let maxUsableSeconds: Double = 10

    /// Bytes transferred since `previous`, or nil when the counters
    /// can't be trusted.
    ///
    /// getifaddrs hands back `if_data`, whose counters are 32-bit, so
    /// they wrap every 4 GiB — a few minutes of a busy tunnel, not a
    /// theoretical edge case. Wrapping subtraction recovers the true
    /// delta across a wrap. A genuine counter reset (the interface was
    /// torn down and recreated) is indistinguishable from a wrap, so a
    /// result implying an impossible rate is reported as nil and the
    /// caller re-baselines instead of drawing a multi-gigabyte spike.
    func delta(from previous: Self) -> (inBytes: UInt64, outBytes: UInt64, seconds: Double)? {
        let seconds = at.timeIntervalSince(previous.at)
        guard seconds > 0, seconds <= Self.maxUsableSeconds else { return nil }
        let ceiling = UInt64(Self.maxPlausibleBytesPerSecond * seconds)
        let down = UInt64(inBytes &- previous.inBytes)
        let up = UInt64(outBytes &- previous.outBytes)
        guard down <= ceiling, up <= ceiling else { return nil }
        return (down, up, seconds)
    }
}

/// Polls the tunnel's counters and latency, emitting one `LinkMetrics`
/// per second for as long as the consumer keeps the stream — modelled
/// on `PowerObserver.events()`, the app's other long-lived stream.
enum LinkMetricsMonitor {

    private static let sampleInterval = Duration.seconds(1)
    /// Latency is probed on its own, slower clock: a ping costs a
    /// subprocess and up to `pingTimeoutSeconds` of wall clock, and RTT
    /// to a gateway doesn't move fast enough to earn that once a second.
    private static let latencyInterval = Duration.seconds(5)
    private static let pingTimeoutSeconds = 2
    /// How many times to go looking for a probe target before giving up
    /// and leaving latency blank.
    ///
    /// More than once, because the first attempt runs while pppd and the
    /// routes are still settling and can plausibly miss every candidate
    /// even though RTT becomes measurable a moment later. Bounded,
    /// because a gateway that simply filters ICMP would otherwise get a
    /// fresh round of echoes forever.
    private static let targetSelectionAttempts = 3
    /// Consecutive silent probes before the current target is abandoned
    /// and the candidates are re-run. A host that has ignored three
    /// echoes in a row isn't coming back on its own, and reporting "—"
    /// for the rest of the session when another candidate would answer
    /// is worse than one more selection sweep.
    private static let failuresBeforeReselect = 3

    /// `fallbackHosts` are probed, in order, when the tunnel's own peer
    /// doesn't answer. They must already be known to route through the
    /// tunnel — see `ConnectionManager.startMetrics`.
    static func stream(interface: String = "ppp0",
                       fallbackHosts: [String]) -> AsyncStream<LinkMetrics> {
        AsyncStream { continuation in
            // Detached, .utility: getifaddrs(3) is a syscall and the
            // ping is a subprocess we block on, so none of this may
            // run on the main actor.
            let task = Task.detached(priority: .utility) {
                await poll(interface: interface,
                           fallbackHosts: fallbackHosts,
                           into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Two concurrent loops: one samples counters on a steady clock, the
    /// other probes latency on its own.
    ///
    /// They have to be separate. An unanswered echo blocks for
    /// `pingTimeoutSeconds`, and a selection sweep blocks for that per
    /// silent candidate — five of them is ten seconds. Sharing one
    /// serial loop meant a sweep stalled the throughput readout no
    /// matter which end of the loop body it sat at: probing before the
    /// yield delayed that tick, probing after it delayed the next one.
    /// Worse, the stalled interval could exceed `maxUsableSeconds`, so
    /// `delta(from:)` would reject the sample outright and Down/Up would
    /// blank for the whole sweep. Split apart, the sampling clock is a
    /// clean one second whatever the gateway does about ICMP.
    private static func poll(interface: String,
                             fallbackHosts: [String],
                             into continuation: AsyncStream<LinkMetrics>.Continuation) async {
        let latency = LatestLatency()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await probeLoop(interface: interface,
                                fallbackHosts: fallbackHosts,
                                into: latency)
            }
            group.addTask {
                await sampleLoop(interface: interface,
                                 latency: latency,
                                 into: continuation)
            }
        }
    }

    /// Reads the byte counters once a second and publishes a rate.
    private static func sampleLoop(interface: String,
                                   latency: LatestLatency,
                                   into continuation: AsyncStream<LinkMetrics>.Continuation) async {
        // Baseline immediately so the first rate can be published one
        // interval from now.
        var previous = InterfaceCounters.read(interface)

        while !Task.isCancelled {
            do { try await Task.sleep(for: sampleInterval) } catch { return }
            if Task.isCancelled { return }

            guard let sample = InterfaceCounters.read(interface) else {
                // The interface is gone, so the connection is already on
                // its way down and ConnectionManager will cancel us
                // shortly. Drop the baseline so that if ppp0 somehow
                // comes back we measure from scratch.
                previous = nil
                continue
            }
            defer { previous = sample }

            // No yield until there are two samples to subtract: one
            // reading is a cumulative total, not a rate.
            guard let last = previous, let delta = sample.delta(from: last) else { continue }

            continuation.yield(LinkMetrics(
                downBytesPerSecond: Double(delta.inBytes) / delta.seconds,
                upBytesPerSecond: Double(delta.outBytes) / delta.seconds,
                // Whatever the probe loop last managed to measure. Never
                // waited on — that's the whole point of the split.
                latencyMilliseconds: await latency.value,
                sampledAt: sample.at
            ))
        }
    }

    /// Keeps a probe target and re-measures it on the latency clock,
    /// re-running selection if the target falls silent.
    private static func probeLoop(interface: String,
                                  fallbackHosts: [String],
                                  into latest: LatestLatency) async {
        var target: String?
        var selectionBudget = targetSelectionAttempts
        var consecutiveFailures = 0

        while !Task.isCancelled {
            if let current = target {
                let measured = await probe(current)
                await latest.set(measured)
                if measured == nil {
                    consecutiveFailures += 1
                    if consecutiveFailures >= failuresBeforeReselect {
                        // Hand the other candidates a turn.
                        target = nil
                        consecutiveFailures = 0
                        selectionBudget = targetSelectionAttempts
                    }
                } else {
                    consecutiveFailures = 0
                }
            } else if selectionBudget > 0 {
                selectionBudget -= 1
                let (host, measured) = await selectTarget(interface: interface,
                                                          fallbackHosts: fallbackHosts)
                target = host
                await latest.set(measured)
            }

            do { try await Task.sleep(for: latencyInterval) } catch { return }
        }
    }

    /// The newest round-trip, handed from the probe loop to the sampling
    /// loop. An actor because the two run concurrently; the read is a
    /// hop, not a wait, which is what keeps the sampling clock steady.
    private actor LatestLatency {
        private(set) var value: Double?
        func set(_ milliseconds: Double?) { value = milliseconds }
    }

    /// Finds the first host that both routes through the tunnel *and*
    /// answers an echo, keeping the round-trip it just measured rather
    /// than throwing it away and pinging the winner a second time.
    ///
    /// Candidates are the point-to-point peer followed by the
    /// gateway-pushed nameservers, and **every one of them** is checked
    /// against `routeInterface(for:)` first. The peer gets no exemption:
    /// on a FortiGate it is typically the gateway's public address, and
    /// openfortivpn deletes the route to it via ppp0 on purpose — so
    /// pinging it measures the ISP path to the concentrator, not the
    /// tunnel, which is the opposite of what this readout claims to be.
    ///
    /// Checks for cancellation between candidates: each silent one costs
    /// `pingTimeoutSeconds`, so a disconnect during selection shouldn't
    /// have to wait the whole list out.
    private static func selectTarget(interface: String,
                                     fallbackHosts: [String]) async -> (String?, Double?) {
        let peer = await offPool { NetworkConfig.peerIPv4(interface) }
        for host in [peer].compactMap({ $0 }) + fallbackHosts {
            if Task.isCancelled { return (nil, nil) }
            let via = await offPool { NetworkConfig.routeInterface(for: host) }
            guard via == interface else { continue }
            if Task.isCancelled { return (nil, nil) }
            if let ms = await probe(host) { return (host, ms) }
        }
        return (nil, nil)
    }

    private static func probe(_ host: String) async -> Double? {
        await offPool {
            NetworkConfig.pingLatencyMilliseconds(host: host, timeoutSeconds: pingTimeoutSeconds)
        }
    }

    /// Runs a blocking helper off the Swift concurrency pool.
    ///
    /// `ping`, `ifconfig` and `route` all go through `runSync`, which
    /// parks its thread in `waitUntilExit` — up to `pingTimeoutSeconds`
    /// for a host that never answers. The cooperative pool is roughly
    /// one thread per core, and it's shared: holding one for seconds at
    /// a time would also stall the reachability check and the driver
    /// output drain, which are the same kind of long-lived task.
    private static func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }
}

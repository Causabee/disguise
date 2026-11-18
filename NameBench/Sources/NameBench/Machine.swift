import Darwin
import Foundation

/// Where the bench ran: the date, the device's model, the OS, "device" or "simulator", the build.
public enum Machine {
    public static var model: String {
        #if targetEnvironment(simulator)
        let env = ProcessInfo.processInfo.environment
        return "\(env["SIMULATOR_DEVICE_NAME"] ?? "simulator") (\(env["SIMULATOR_MODEL_IDENTIFIER"] ?? "?"))"
        #else
        var size = 0
        let key = isMac ? "hw.model" : "hw.machine"
        sysctlbyname(key, nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    public static var kind: String {
        #if targetEnvironment(simulator)
        "simulator"
        #else
        "device"
        #endif
    }

    public static var build: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    public static func header(_ what: String, run: String) -> String {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        return "F021 AC-1 · \(day) · \(model) · \(ProcessInfo.processInfo.operatingSystemVersionString) · \(kind) · build: \(run), \(build) · \(what)"
    }

    /// This process's resident size and its highest so far, in bytes, by `task_info`.
    public static func memory() -> (resident: UInt64, highest: UInt64) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.resident_size, info.resident_size_max)
    }
}

/// Samples the resident size while a candidate runs, so its peak is its own and not the process's
/// highest since it started.
final class Sampler: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: UInt64 = 0
    private var running = true
    private var thread: Thread?

    func start() {
        highest = Machine.memory().resident
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let now = Machine.memory().resident
                lock.withLock { highest = max(highest, now) }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        self.thread = thread
        thread.start()
    }

    func stop() -> UInt64 {
        lock.withLock { running = false }
        let now = Machine.memory().resident
        return lock.withLock { max(highest, now) }
    }
}

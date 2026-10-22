import Darwin
import Foundation

/// The app's memory as iOS counts it against the app's limit: its footprint now, and the highest
/// it has been in this process.
struct MemoryFootprint: Equatable, Sendable {
    let footprintBytes: Int
    let peakBytes: Int

    /// Now, from the kernel's `task_vm_info`; nil if it can't say.
    static func now() -> MemoryFootprint? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let footprint = Int(clamping: info.phys_footprint)
        return MemoryFootprint(
            footprintBytes: footprint, peakBytes: max(footprint, Int(clamping: info.ledger_phys_footprint_peak)))
    }
}

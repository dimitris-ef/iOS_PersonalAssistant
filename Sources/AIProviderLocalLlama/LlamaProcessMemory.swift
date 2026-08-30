import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The process's real memory footprint, when the OS will say.
///
/// ## Why this is not another estimate
///
/// Section 47 draws a distinction the previous pass blurred. Three different
/// numbers were all being called "memory":
///
/// - `estimatedInferenceMemory` — what the app's own model *predicts* a load
///   will cost. A calculation.
/// - `availableMemoryEstimate` — a fraction of physical RAM chosen by policy.
///   Also a calculation, and explicitly not free memory, which iOS does not
///   publish.
/// - **this** — `phys_footprint` from `task_info`, the same figure the memory
///   gauge in Xcode shows and the one jetsam actually decides on.
///
/// Only the third is a measurement, so only the third is named without the word
/// "estimate". Reporting a prediction where a measurement was expected is how a
/// diagnosis goes wrong.
///
/// Returns nil rather than zero when the call fails: a zero would read as "no
/// memory in use", which is never true and would be worse than saying nothing.
enum LlamaProcessMemory {

    static func footprintBytes() -> Int64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // `phys_footprint` rather than `resident_size`: the footprint is what
        // counts against the jetsam limit, and resident size omits compressed
        // pages that still belong to the process.
        return Int64(info.phys_footprint)
        #else
        return nil
        #endif
    }
}

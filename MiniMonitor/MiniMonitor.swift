import Foundation
import IOKit
import Combine

@MainActor
final class MiniMonitor: ObservableObject {
    @Published var cpuPercent: Double? = nil
    @Published var ramUsedGB: Double? = nil
    @Published var ramTotalGB: Double? = nil
    @Published var gpuPercent: Double? = nil

    private var timer: Timer?
    private var gpuService: io_service_t = 0
    private var prevUser: UInt64 = 0
    private var prevSys:  UInt64 = 0
    private var prevIdle: UInt64 = 0
    private var prevNice: UInt64 = 0

    init() {
        gpuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.read() }
        }
    }

    deinit {
        timer?.invalidate()
        if gpuService != 0 { IOObjectRelease(gpuService) }
    }

    func read() {
        readCPU()
        readRAM()
        readGPU()
    }

    private func readCPU() {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        let user = UInt64(info.cpu_ticks.0)
        let sys  = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        let dUser = user - prevUser
        let dSys  = sys  - prevSys
        let dIdle = idle - prevIdle
        let dNice = nice - prevNice
        let total = dUser + dSys + dIdle + dNice

        if total > 0 {
            let new = Double(dUser + dSys + dNice) / Double(total) * 100.0
            if abs((cpuPercent ?? -99) - new) > 1.0 { cpuPercent = new }
        }

        prevUser = user; prevSys = sys; prevIdle = idle; prevNice = nice
    }

    private func readRAM() {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }

        let pageSize = Double(vm_page_size)
        let used  = Double(info.active_count + info.wire_count + info.compressor_page_count) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)

        let newUsed = used / 1_073_741_824
        if abs((ramUsedGB ?? -99) - newUsed) > 0.05 { ramUsedGB = newUsed }
        if ramTotalGB == nil { ramTotalGB = total / 1_073_741_824 }
    }

    private func readGPU() {
        guard gpuService != 0 else { return }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(gpuService, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any],
              let stats = dict["PerformanceStatistics"] as? [String: Any] else { return }

        if let v = stats["Device Utilization %"] as? Double {
            if abs((gpuPercent ?? -99) - v) > 1.0 { gpuPercent = v }
        }
    }
}

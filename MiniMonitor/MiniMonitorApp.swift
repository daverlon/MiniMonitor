import SwiftUI
import ServiceManagement
import AppKit
import Combine

@main
struct MiniMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let monitor = MiniMonitor()
    var popover: NSPopover?
    var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            updateButtonTitle(button)
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 200, height: 160)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(monitor: monitor, appDelegate: self)
        )
        self.popover = popover

        monitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if let button = self?.statusItem?.button { self?.updateButtonTitle(button) }
            }
            .store(in: &cancellables)
    }

    func refreshTitle() {
        if let button = statusItem?.button { updateButtonTitle(button) }
    }

    func updateButtonTitle(_ button: NSButton) {
        let showCPU = UserDefaults.standard.object(forKey: "showCPU") as? Bool ?? true
        let showRAM = UserDefaults.standard.object(forKey: "showRAM") as? Bool ?? true
        let showGPU = UserDefaults.standard.object(forKey: "showGPU") as? Bool ?? true

        let cpu = monitor.cpuPercent
        let ram = monitor.ramUsedGB
        let total = monitor.ramTotalGB
        let gpu = monitor.gpuPercent

        let cpuStr = cpu.map { String(format: "%1.0f%%", $0) } ?? "—"
        let ramStr = (ram != nil && total != nil) ? String(format: "%1.0f%%", ram! / total! * 100.0) : "—"
        let gpuStr = gpu.map { String(format: "%1.0f%%", $0) } ?? "—"

        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .light)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.controlTextColor,
            .baselineOffset: -1.5
        ]

        func symbol(_ name: String) -> NSAttributedString {
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            let cell = NSTextAttachment()
            cell.image = img
            let a = NSMutableAttributedString(attachment: cell)
            a.addAttributes(attrs, range: NSRange(location: 0, length: a.length))
            return a
        }

        let result = NSMutableAttributedString()
        if showCPU {
            result.append(symbol("cpu"))
            result.append(NSAttributedString(string: "\(cpuStr) ", attributes: attrs))
        }
        if showRAM {
            result.append(symbol("memorychip"))
            result.append(NSAttributedString(string: "\(ramStr) ", attributes: attrs))
        }
        if showGPU {
            result.append(symbol("display"))
            result.append(NSAttributedString(string: "\(gpuStr)", attributes: attrs))
        }
        if result.length == 0 {
            result.append(NSAttributedString(string: "—", attributes: attrs))
        }

        guard button.attributedTitle.string != result.string else { return }
        button.attributedTitle = result
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        popover.isShown
            ? popover.performClose(nil)
            : popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func quit() { NSApplication.shared.terminate(nil) }
}

struct PopoverView: View {
    @ObservedObject var monitor: MiniMonitor
    var appDelegate: AppDelegate

    @AppStorage("showCPU") private var showCPU = true
    @AppStorage("showRAM") private var showRAM = true
    @AppStorage("showGPU") private var showGPU = true

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isHoveringStartup = false
    @State private var isHoveringQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(label: "cpu", value: pctString(monitor.cpuPercent), visible: $showCPU)
                .onChange(of: showCPU) { _, _ in appDelegate.refreshTitle() }
            row(label: "ram", value: ramString, visible: $showRAM)
                .onChange(of: showRAM) { _, _ in appDelegate.refreshTitle() }
            row(label: "gpu", value: pctString(monitor.gpuPercent), visible: $showGPU)
                .onChange(of: showGPU) { _, _ in appDelegate.refreshTitle() }

            Divider()

            Toggle("launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: 11, weight: .light, design: .monospaced))
                .onChange(of: launchAtLogin) { _, enabled in
                    try? enabled
                        ? SMAppService.mainApp.register()
                        : SMAppService.mainApp.unregister()
                }
                .foregroundStyle(isHoveringStartup ? .primary : .secondary)
                .onHover { isHoveringStartup = $0 }

            Button("Quit") { appDelegate.quit() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .light, design: .monospaced))
                .foregroundStyle(isHoveringQuit ? .primary : .secondary)
                .onHover { isHoveringQuit = $0 }
        }
        .padding(16)
        .frame(width: 200)
        .font(.system(size: 11, weight: .light, design: .monospaced))
    }

    func row(label: String, value: String, visible: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: visible)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    func pctString(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f%%", v)
    }

    var ramString: String {
        guard let used = monitor.ramUsedGB, let total = monitor.ramTotalGB else { return "—" }
        return String(format: "%.1f / %.0f GB", used, total)
    }
}

import AppKit
import Darwin

// MARK: - Kernel queries

func loadTotalBytes() -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    let r = withUnsafeMutablePointer(to: &value) { ptr in
        sysctlbyname("hw.memsize", UnsafeMutableRawPointer(ptr), &size, nil, 0)
    }
    if r == 0 && value > 0 { return value }
    return ProcessInfo.processInfo.physicalMemory
}

func loadSwapUsed() -> UInt64 {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    let r = withUnsafeMutablePointer(to: &usage) { ptr in
        sysctlbyname("vm.swapusage", UnsafeMutableRawPointer(ptr), &size, nil, 0)
    }
    guard r == 0 else { return 0 }
    return usage.xsu_used
}

func loadPageSize() -> UInt64 {
    var ps: vm_size_t = 0
    if host_page_size(mach_host_self(), &ps) == KERN_SUCCESS && ps > 0 {
        return UInt64(ps)
    }
    return UInt64(getpagesize())
}

struct MemSnapshot {
    let total: UInt64
    let used: UInt64
    let available: UInt64
    let swapUsed: UInt64
    let percent: Int
}

func currentSnapshot(total: UInt64, pageSize: UInt64) -> MemSnapshot? {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &stats) { sPtr in
        sPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { iPtr in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, iPtr, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }

    let internalPages = UInt64(stats.internal_page_count)
    let purgeablePages = UInt64(stats.purgeable_count)
    let appPages = internalPages >= purgeablePages ? internalPages - purgeablePages : 0
    let wiredPages = UInt64(stats.wire_count)
    let compressedPages = UInt64(stats.compressor_page_count)

    let used = (appPages + wiredPages + compressedPages) * pageSize
    let available = total > used ? total - used : 0
    let percent = total > 0 ? Int((Double(used) / Double(total)) * 100.0) : 0
    return MemSnapshot(
        total: total,
        used: used,
        available: available,
        swapUsed: loadSwapUsed(),
        percent: percent
    )
}

// MARK: - Formatting

private let ptBRLocale = Locale(identifier: "pt_BR")

func formatGB(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", locale: ptBRLocale, Double(bytes) / 1_073_741_824.0)
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    private let totalItem = NSMenuItem(title: "Memória Total: …", action: nil, keyEquivalent: "")
    private let usedItem = NSMenuItem(title: "Em Uso: …", action: nil, keyEquivalent: "")
    private let availItem = NSMenuItem(title: "Disponível: …", action: nil, keyEquivalent: "")
    private let swapItem = NSMenuItem(title: "Swap Usado: …", action: nil, keyEquivalent: "")

    private let totalBytes: UInt64 = loadTotalBytes()
    private let pageSize: UInt64 = loadPageSize()

    private static let cachedIcon: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let img = NSImage(
            systemSymbolName: "memorychip",
            accessibilityDescription: "Monitor de RAM"
        ) else { return nil }
        let configured = img.withSymbolConfiguration(cfg) ?? img
        configured.isTemplate = true
        configured.size = NSSize(width: 16, height: 16)
        return configured
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = Self.cachedIcon
            button.toolTip = "Monitor de RAM"
            button.setAccessibilityLabel("Monitor de RAM")
        }

        for item in [totalItem, usedItem, availItem, swapItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        guard let snap = currentSnapshot(total: totalBytes, pageSize: pageSize) else {
            totalItem.title = "Memória Total: indisponível"
            usedItem.title = "Em Uso: indisponível"
            availItem.title = "Disponível: indisponível"
            swapItem.title = "Swap Usado: indisponível"
            statusItem.button?.toolTip = "Monitor de RAM"
            return
        }
        totalItem.title = "Memória Total: \(formatGB(snap.total))"
        usedItem.title = "Em Uso: \(formatGB(snap.used)) (\(snap.percent)%)"
        availItem.title = "Disponível: \(formatGB(snap.available))"
        swapItem.title = "Swap Usado: \(formatGB(snap.swapUsed))"
        let tip = "\(formatGB(snap.used)) de \(formatGB(snap.total)) em uso — inclui cache liberável"
        statusItem.button?.toolTip = tip
        statusItem.button?.setAccessibilityLabel("RAM: \(tip)")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

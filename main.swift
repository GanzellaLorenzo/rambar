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

// MARK: - WindowServer (lido do log do wsmon, sem rodar `top`)

struct WSSample {
    let mb: Int
    let at: Date
}

private let wsLogPath = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Logs/wsmon.log")

private let wsLogFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

/// Última linha do log do wsmon: `2026-11-23 14:54,489`
func loadWindowServerSample() -> WSSample? {
    guard let data = FileManager.default.contents(atPath: wsLogPath),
          let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.split(whereSeparator: \.isNewline)
    guard let last = lines.last else { return nil }
    let parts = last.split(separator: ",", maxSplits: 1)
    guard parts.count == 2,
          let mb = Int(parts[1].trimmingCharacters(in: .whitespaces)),
          let at = wsLogFormatter.date(from: String(parts[0])) else { return nil }
    return WSSample(mb: mb, at: at)
}

/// PID do WindowServer (resolvido uma vez; sobrevive até o próximo reboot).
private func resolveWindowServerPID() -> pid_t? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "WindowServer"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = pid_t(text) else { return nil }
    return pid
}

/// Footprint ao vivo via `top` (~0,36 s). Requer root para `proc_pid_rusage`,
/// por isso `top` é o único caminho sem privilégio.
func loadWindowServerFootprintMB(pid: pid_t) -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
    p.arguments = ["-l", "1", "-pid", "\(pid)", "-stats", "mem"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    for raw in text.split(whereSeparator: \.isNewline).reversed() {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasSuffix("M"), let v = Int(line.dropLast()) { return v }
        if line.hasSuffix("G"), let v = Double(line.dropLast()) { return Int(v * 1024) }
    }
    return nil
}

// MARK: - Formatting

private let ptBRLocale = Locale(identifier: "pt_BR")

func formatGB(_ bytes: UInt64) -> String {
    String(format: "%.1f GB", locale: ptBRLocale, Double(bytes) / 1_073_741_824.0)
}

func formatMB(_ mb: Int) -> String {
    if mb >= 1024 {
        return String(format: "%.1f GB", locale: ptBRLocale, Double(mb) / 1024.0)
    }
    return "\(mb) MB"
}

func formatAge(_ date: Date) -> String {
    let minutes = Int(Date().timeIntervalSince(date) / 60)
    if minutes < 1 { return "agora" }
    if minutes < 60 { return "há \(minutes) min" }
    let hours = minutes / 60
    if hours < 24 { return "há \(hours) h" }
    return "há \(hours / 24) d"
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
    private let wsItem = NSMenuItem(title: "WindowServer: …", action: nil, keyEquivalent: "")

    /// Limiar de atenção: o reboot é recomendado acima disto.
    private let wsAlertMB = 1200
    private let wsWarnMB = 900

    private let totalBytes: UInt64 = loadTotalBytes()
    private let pageSize: UInt64 = loadPageSize()
    private let wsPID: pid_t? = resolveWindowServerPID()

    private static let cachedIcon: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let img = NSImage(
            systemSymbolName: "memorychip",
            accessibilityDescription: "Monitor de RAM"
        ) else { return nil }
        let configured = img.withSymbolConfiguration(cfg) ?? img
        configured.isTemplate = true
        configured.size = NSSize(width: 15, height: 15)
        return configured
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = Self.cachedIcon
            button.toolTip = "Monitor de RAM"
            button.setAccessibilityLabel("Monitor de RAM")
        }

        for item in [totalItem, usedItem, availItem, swapItem, wsItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let openLog = NSMenuItem(title: "Abrir log do wsmon", action: #selector(openLog), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)
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

    /// Zero polling: mede ao vivo no clique; cai para o log se falhar.
    private func refreshWS() {
        var mb: Int?
        var age: String = "agora"
        if let pid = wsPID, let live = loadWindowServerFootprintMB(pid: pid) {
            mb = live
        } else if let sample = loadWindowServerSample() {
            mb = sample.mb
            age = formatAge(sample.at)
        }
        guard let value = mb else {
            wsItem.title = "WindowServer: sem dados"
            return
        }
        let formatted = formatMB(value)
        let text = "WindowServer: \(formatted) (\(age))"
        let color: NSColor
        if value >= wsAlertMB {
            color = .systemRed
        } else if value >= wsWarnMB {
            color = .systemOrange
        } else {
            color = .labelColor
        }
        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttribute(
            .foregroundColor,
            value: color,
            range: (text as NSString).range(of: formatted)
        )
        wsItem.attributedTitle = attributed
        wsItem.toolTip = "Footprint do WindowServer medido no clique; reboot acima de \(wsAlertMB) MB"
    }

    private func refresh() {
        refreshWS()
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
        statusItem.button?.setAccessibilityLabel("RAM \(snap.percent)% — WindowServer")
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: wsLogPath))
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

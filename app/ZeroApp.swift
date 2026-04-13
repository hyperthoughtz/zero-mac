import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var configInode: UInt64 = 0
    private var suppressWatcher = false
    private var pendingReload: DispatchWorkItem?

    private let configDir = NSHomeDirectory() + "/.config/mihomo"
    private let logPath = "/usr/local/var/log/mihomo.log"

    private var configPath: String { configDir + "/config.yaml" }

    // MARK: - Config Readers

    private var apiBase: String {
        let ec = readConfigValue(key: "external-controller")
        if ec.isEmpty { return "http://127.0.0.1:9090" }
        return "http://\(ec)"
    }

    private var apiPort: String {
        let ec = readConfigValue(key: "external-controller")
        return ec.components(separatedBy: ":").last ?? "9090"
    }

    private var secret: String { readConfigValue(key: "secret") }

    private var tunEnabled: Bool {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
        var inTun = false
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("tun:") { inTun = true; continue }
            if inTun {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("enable:") { return t.contains("true") }
                if !line.hasPrefix(" ") && !t.isEmpty { break }
            }
        }
        return false
    }

    private var currentSubURL: String {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return "" }
        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if line.contains("proxy-providers:") {
                for j in (i+1)..<min(i+6, lines.count) {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("url:") {
                        var v = t.replacingOccurrences(of: "url:", with: "").trimmingCharacters(in: .whitespaces)
                        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        return v
                    }
                }
            }
        }
        return ""
    }

    private func readConfigValue(key: String) -> String {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return "" }
        for line in content.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\(key):") {
                var v = t.replacingOccurrences(of: "\(key):", with: "").trimmingCharacters(in: .whitespaces)
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v
            }
        }
        return ""
    }

    // MARK: - Config Writing

    private func writeConfig(_ content: String) {
        suppressWatcher = true
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.suppressWatcher = false
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button { button.title = "△" }
        buildMenu()
        startWatchers()
        updateStatus()

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        setSysProxyForAllServices(enabled: false, port: "")
    }

    // MARK: - Config Watcher (dual: directory for rename/replace + file for in-place write)

    private func startWatchers() {
        watchConfigDir()
        watchConfigFile()
    }

    private func scheduleReload() {
        guard !suppressWatcher else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadMihomoConfig()
            self?.updateStatus()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func currentConfigInode() -> UInt64 {
        var st = stat()
        guard stat(configPath, &st) == 0 else { return 0 }
        return UInt64(st.st_ino)
    }

    private func watchConfigDir() {
        let fd = open(configDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Only react if config.yaml's inode changed (file was replaced)
            let newInode = self.currentConfigInode()
            guard newInode != self.configInode && newInode != 0 else { return }
            self.configInode = newInode
            self.watchConfigFile()
            self.scheduleReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirWatcher = source
    }

    private func watchConfigFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        configInode = currentConfigInode()

        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.scheduleReload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    // MARK: - mihomo API Control

    private func reloadMihomoConfig(completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "\(apiBase)/configs?force=true") else {
            completion?(false); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 5
        let s = secret
        if !s.isEmpty { request.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": configPath])
        URLSession.shared.dataTask(with: request) { [weak self] _, resp, err in
            let ok = err == nil && (resp as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.updateStatus()
                completion?(ok)
            }
        }.resume()
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        let st = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
        st.tag = 1; menu.addItem(st)

        let sub = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sub.tag = 2; sub.isEnabled = false; menu.addItem(sub)

        menu.addItem(NSMenuItem.separator())

        let sp = NSMenuItem(title: "System Proxy", action: #selector(toggleSysProxy), keyEquivalent: "p")
        sp.tag = 10; menu.addItem(sp)

        let tn = NSMenuItem(title: "TUN Mode", action: #selector(toggleTUN), keyEquivalent: "t")
        tn.tag = 11; menu.addItem(tn)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Set Subscription...", action: #selector(setSubscription), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Open Web UI", action: #selector(openUI), keyEquivalent: "u"))
        menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "View Log", action: #selector(openLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Zero", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - Status

    private func updateStatus() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let running = self.isRunning()
            let url = self.currentSubURL
            let tun = self.tunEnabled
            let sysProxy = self.isSysProxyEnabled()
            DispatchQueue.main.async {
                self.statusItem.button?.title = running ? "▲" : "△"
                self.statusItem.menu?.item(withTag: 1)?.title = running ? "● Running" : "○ Stopped"
                if let item = self.statusItem.menu?.item(withTag: 2) {
                    if url.isEmpty || url.contains("${SUB_URL}") {
                        item.title = "⚠ No subscription"
                    } else {
                        item.title = "↻ " + (url.count > 35 ? String(url.prefix(35)) + "..." : url)
                    }
                }
                self.statusItem.menu?.item(withTag: 10)?.state = sysProxy ? .on : .off
                self.statusItem.menu?.item(withTag: 11)?.state = tun ? .on : .off
            }
        }
    }

    private func isRunning() -> Bool {
        guard let url = URL(string: "\(apiBase)/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let s = secret
        if !s.isEmpty { request.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { ok = true }
            sem.signal()
        }.resume()
        sem.wait()
        return ok
    }

    // MARK: - System Proxy (NO admin password needed)

    private func allNetworkServices() -> [String] {
        let out = shell("/usr/sbin/networksetup", ["-listallnetworkservices"])
        return out.components(separatedBy: "\n").dropFirst().filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    private func isSysProxyEnabled() -> Bool {
        for svc in allNetworkServices() {
            let out = shell("/usr/sbin/networksetup", ["-getwebproxy", svc])
            if out.contains("Enabled: Yes") { return true }
        }
        return false
    }

    @objc private func toggleSysProxy() {
        let port = readConfigValue(key: "mixed-port").isEmpty ? "7890" : readConfigValue(key: "mixed-port")
        let enable = !isSysProxyEnabled()
        setSysProxyForAllServices(enabled: enable, port: port)
        updateStatus()
    }

    private func setSysProxyForAllServices(enabled: Bool, port: String) {
        for svc in allNetworkServices() {
            if enabled {
                shell("/usr/sbin/networksetup", ["-setwebproxy", svc, "127.0.0.1", port])
                shell("/usr/sbin/networksetup", ["-setsecurewebproxy", svc, "127.0.0.1", port])
                shell("/usr/sbin/networksetup", ["-setsocksfirewallproxy", svc, "127.0.0.1", port])
            } else {
                shell("/usr/sbin/networksetup", ["-setwebproxystate", svc, "off"])
                shell("/usr/sbin/networksetup", ["-setsecurewebproxystate", svc, "off"])
                shell("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", svc, "off"])
            }
        }
    }

    // MARK: - Config Mutation (write + reload + rollback on failure)

    private func applyConfigChange(_ transform: (String) -> String?) {
        guard let original = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        guard let modified = transform(original), modified != original else { return }
        writeConfig(modified)
        reloadMihomoConfig { [weak self] ok in
            guard let self = self else { return }
            if !ok {
                self.writeConfig(original)
                let alert = NSAlert()
                alert.messageText = "Config reload failed"
                alert.informativeText = "mihomo rejected the configuration. Changes have been rolled back."
                alert.alertStyle = .warning
                alert.runModal()
            }
            self.updateStatus()
        }
    }

    // MARK: - TUN Toggle (no password — daemon is already root)

    @objc private func toggleTUN() {
        let newState = !tunEnabled
        applyConfigChange { content in
            var lines = content.components(separatedBy: "\n")
            var inTun = false
            for (i, line) in lines.enumerated() {
                if line.hasPrefix("tun:") { inTun = true; continue }
                if inTun && line.trimmingCharacters(in: .whitespaces).hasPrefix("enable:") {
                    lines[i] = "  enable: \(newState)"; break
                }
                if inTun && !line.hasPrefix(" ") && !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Subscription

    @objc private func setSubscription() {
        let alert = NSAlert()
        alert.messageText = "Set Subscription URL"
        alert.informativeText = "Paste your proxy subscription link. mihomo auto-fetches nodes every hour."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 60))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 60))
        textView.isEditable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        let current = currentSubURL
        textView.string = (current.contains("${SUB_URL}") || current.isEmpty) ? "" : current
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            let url = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                applyConfigChange { content in
                    var lines = content.components(separatedBy: "\n")
                    var inP = false, inS = false
                    for (i, line) in lines.enumerated() {
                        if line.contains("proxy-providers:") { inP = true; continue }
                        if inP && line.contains("subscription:") { inS = true; continue }
                        if inS && line.trimmingCharacters(in: .whitespaces).hasPrefix("url:") {
                            let indent = String(line.prefix(while: { $0 == " " }))
                            lines[i] = "\(indent)url: \"\(url)\""; break
                        }
                        if inS && !line.hasPrefix("    ") && !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    }
                    return lines.joined(separator: "\n")
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func openUI() {
        // Write config.js so metacubexd auto-connects without login page
        let s = secret
        let uiConfigPath = configDir + "/ui/config.js"
        let uiConfig = "window.__METACUBEXD_CONFIG__ = {\n  defaultBackendURL: '\(apiBase)',\n  secret: '\(s)',\n}"
        try? uiConfig.write(toFile: uiConfigPath, atomically: true, encoding: .utf8)

        let urlStr = "\(apiBase)/ui/#/setup?hostname=127.0.0.1&port=\(apiPort)&secret=\(s)"
        if let url = URL(string: urlStr) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc private func openLog() {
        let script = "tell application \"Terminal\" to do script \"tail -100f \(logPath)\""
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }

    // MARK: - Helpers

    @discardableResult
    private func shell(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.launchPath = path
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return "" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

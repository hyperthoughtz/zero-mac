import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var configWatcher: DispatchSourceFileSystemObject?
    private var mihomoProcess: Process?
    private var suppressWatcher = false  // prevent self-triggered restarts
    private var pendingRestart: DispatchWorkItem?

    private let mihomoPath = "/usr/local/bin/mihomo"
    private let apiBase = "http://127.0.0.1:9090"
    private let configDir = NSHomeDirectory() + "/.config/mihomo"
    private let logPath = "/usr/local/var/log/mihomo.log"
    private let maxLogSize: UInt64 = 5 * 1024 * 1024  // 5MB

    private var configPath: String { configDir + "/config.yaml" }
    private var templatePath: String {
        let installed = "/usr/local/share/mihomo/config.yaml.template"
        if FileManager.default.fileExists(atPath: installed) { return installed }
        let bundled = Bundle.main.bundlePath + "/../../config/config.yaml.template"
        if FileManager.default.fileExists(atPath: bundled) { return bundled }
        return installed
    }

    // MARK: - Config Readers

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

    // MARK: - Config Writing (suppresses watcher)

    private func writeConfig(_ content: String) {
        suppressWatcher = true
        try? content.write(toFile: configPath, atomically: true, encoding: .utf8)
        // Re-enable watcher after filesystem events settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.suppressWatcher = false
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button { button.title = "△" }
        buildMenu()
        rotateLogIfNeeded()
        ensureConfig()
        startMihomo()
        watchConfig()

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.updateStatus()
            self?.rotateLogIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMihomo()
    }

    // MARK: - Config Management

    private func ensureConfig() {
        let fm = FileManager.default
        if fm.fileExists(atPath: configPath) { return }

        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        let sec = randomHex(16)
        if let template = try? String(contentsOfFile: templatePath, encoding: .utf8) {
            let config = template
                .replacingOccurrences(of: "${SECRET}", with: sec)
                .replacingOccurrences(of: "${SUB_URL}", with: "")
            writeConfig(config)
        }
    }

    private func watchConfig() {
        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self, !self.suppressWatcher else { return }
            // Debounce: cancel previous pending restart, schedule new one
            self.pendingRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.restartMihomo()
            }
            self.pendingRestart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        let st = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
        st.tag = 1
        menu.addItem(st)

        let sub = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sub.tag = 2; sub.isEnabled = false
        menu.addItem(sub)

        menu.addItem(NSMenuItem.separator())

        let sp = NSMenuItem(title: "System Proxy", action: #selector(toggleSysProxy), keyEquivalent: "p")
        sp.tag = 10
        menu.addItem(sp)

        let tn = NSMenuItem(title: "TUN Mode", action: #selector(toggleTUN), keyEquivalent: "t")
        tn.tag = 11
        menu.addItem(tn)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Set Subscription...", action: #selector(setSubscription), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Open Web UI", action: #selector(openUI), keyEquivalent: "u"))
        menu.addItem(NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "View Log", action: #selector(openLog), keyEquivalent: "l"))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Zero", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    // MARK: - mihomo Process

    private func startMihomo() {
        guard FileManager.default.fileExists(atPath: configPath) else { return }
        guard !isRunning() else {
            updateStatus()
            return
        }

        if tunEnabled {
            startAsRoot()
        } else {
            startAsUser()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.updateStatus()
        }
    }

    private func startAsUser() {
        if mihomoProcess?.isRunning == true { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mihomoPath)
        proc.arguments = ["-d", configDir]
        FileManager.default.createFile(atPath: logPath, contents: nil)
        proc.standardOutput = FileHandle(forWritingAtPath: logPath)
        proc.standardError = FileHandle(forWritingAtPath: logPath)

        proc.terminationHandler = { [weak self] p in
            guard p.terminationStatus != 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.mihomoProcess = nil
                self?.startMihomo()
            }
        }

        do {
            try proc.run()
            mihomoProcess = proc
        } catch { /* will show as stopped */ }
    }

    /// Returns true if root process started successfully
    @discardableResult
    private func startAsRoot() -> Bool {
        let cmd = "\(mihomoPath) -d \(configDir) >> \(logPath) 2>&1 &"
        return runPrivilegedSync(cmd)
    }

    private func stopMihomo() {
        // Kill user-owned child
        if let proc = mihomoProcess, proc.isRunning {
            proc.terminationHandler = nil
            proc.terminate()
            mihomoProcess = nil
        }
        // Kill any mihomo for this config (user-owned)
        let kill = Process()
        kill.launchPath = "/usr/bin/pkill"
        kill.arguments = ["-f", "\(mihomoPath) -d \(configDir)"]
        try? kill.run()
        kill.waitUntilExit()

        // Kill root-owned mihomo
        if isRunning() {
            _ = runPrivilegedSync("pkill -f '\(mihomoPath) -d \(configDir)'")
        }
    }

    private func restartMihomo() {
        stopMihomo()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startMihomo()
        }
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

                if let item = self.statusItem.menu?.item(withTag: 1) {
                    item.title = running ? "● Running" : "○ Stopped"
                }
                if let item = self.statusItem.menu?.item(withTag: 2) {
                    if url.isEmpty || url.contains("${SUB_URL}") {
                        item.title = "⚠ No subscription"
                    } else {
                        let d = url.count > 35 ? String(url.prefix(35)) + "..." : url
                        item.title = "↻ " + d
                    }
                }
                self.statusItem.menu?.item(withTag: 10)?.state = sysProxy ? .on : .off
                self.statusItem.menu?.item(withTag: 11)?.state = tun ? .on : .off
            }
        }
    }

    private func isRunning() -> Bool {
        var request = URLRequest(url: URL(string: "\(apiBase)/version")!)
        request.timeoutInterval = 2
        let s = secret
        if !s.isEmpty { request.setValue("Bearer \(s)", forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { ok = true }
            sem.signal()
        }.resume()
        sem.wait()
        return ok
    }

    // MARK: - System Proxy

    private func isSysProxyEnabled() -> Bool {
        let proc = Process()
        proc.launchPath = "/usr/sbin/networksetup"
        proc.arguments = ["-getwebproxy", "Wi-Fi"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("Enabled: Yes")
    }

    @objc private func toggleSysProxy() {
        let port = readConfigValue(key: "mixed-port").isEmpty ? "7890" : readConfigValue(key: "mixed-port")

        if isSysProxyEnabled() {
            _ = runPrivilegedSync("""
                for svc in $(networksetup -listallnetworkservices | tail -n +2); do
                    networksetup -setwebproxystate "$svc" off 2>/dev/null
                    networksetup -setsecurewebproxystate "$svc" off 2>/dev/null
                    networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null
                done
            """)
        } else {
            _ = runPrivilegedSync("""
                for svc in $(networksetup -listallnetworkservices | tail -n +2); do
                    networksetup -setwebproxy "$svc" 127.0.0.1 \(port) 2>/dev/null
                    networksetup -setsecurewebproxy "$svc" 127.0.0.1 \(port) 2>/dev/null
                    networksetup -setsocksfirewallproxy "$svc" 127.0.0.1 \(port) 2>/dev/null
                done
            """)
        }
        updateStatus()
    }

    // MARK: - TUN Toggle

    @objc private func toggleTUN() {
        let wasEnabled = tunEnabled
        let newState = !wasEnabled

        // Write new TUN state
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        var inTun = false
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("tun:") { inTun = true; continue }
            if inTun && line.trimmingCharacters(in: .whitespaces).hasPrefix("enable:") {
                lines[i] = "  enable: \(newState)"
                break
            }
            if inTun && !line.hasPrefix(" ") && !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
        }
        writeConfig(lines.joined(separator: "\n"))

        // Immediately update UI
        statusItem.menu?.item(withTag: 11)?.state = newState ? .on : .off

        // Restart mihomo with new config
        stopMihomo()

        if newState {
            // Enabling TUN: needs root
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self = self else { return }
                let ok = self.startAsRoot()

                // Wait and check if it actually started
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self = self else { return }
                    if !self.isRunning() && !ok {
                        // Failed (user cancelled password) → rollback config
                        var rollback = lines
                        var rt = false
                        for (i, line) in rollback.enumerated() {
                            if line.hasPrefix("tun:") { rt = true; continue }
                            if rt && line.trimmingCharacters(in: .whitespaces).hasPrefix("enable:") {
                                rollback[i] = "  enable: \(wasEnabled)"
                                break
                            }
                            if rt && !line.hasPrefix(" ") && !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                        }
                        self.writeConfig(rollback.joined(separator: "\n"))
                        // Restart without TUN
                        self.startMihomo()
                    }
                    self.updateStatus()
                }
            }
        } else {
            // Disabling TUN: no root needed
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startMihomo()
            }
        }
    }

    // MARK: - Subscription

    @objc private func setSubscription() {
        let alert = NSAlert()
        alert.messageText = "Set Subscription URL"
        alert.informativeText = "Paste your proxy subscription link.\nmihomo auto-fetches nodes every hour."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        let current = currentSubURL
        input.stringValue = (current.contains("${SUB_URL}") || current.isEmpty) ? "" : current
        input.placeholderString = "https://provider.com/sub?token=xxx"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            let url = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                updateConfigLine(under: "proxy-providers:", section: "subscription:", key: "url:", value: "\"\(url)\"")
                restartMihomo()
            }
        }
    }

    // MARK: - Actions

    @objc private func openUI() {
        NSWorkspace.shared.open(URL(string: "\(apiBase)/ui")!)
    }

    @objc private func openConfig() {
        ensureConfig()
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    @objc private func openLog() {
        let script = "tell application \"Terminal\" to do script \"tail -100f \(logPath)\""
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        try? proc.run()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Log Rotation

    private func rotateLogIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? UInt64, size > maxLogSize,
              let handle = FileHandle(forUpdatingAtPath: logPath) else { return }
        let keep: UInt64 = 1024 * 1024
        if size > keep {
            handle.seek(toFileOffset: size - keep)
            let tail = handle.readDataToEndOfFile()
            handle.truncateFile(atOffset: 0)
            handle.seek(toFileOffset: 0)
            handle.write(tail)
        }
        handle.closeFile()
    }

    // MARK: - Helpers

    private func updateConfigLine(under parent: String, section: String, key: String, value: String) {
        guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else { return }
        var lines = content.components(separatedBy: "\n")
        var inP = false, inS = false
        for (i, line) in lines.enumerated() {
            if line.contains(parent) { inP = true; continue }
            if inP && line.contains(section) { inS = true; continue }
            if inS && line.trimmingCharacters(in: .whitespaces).hasPrefix(key) {
                let indent = String(line.prefix(while: { $0 == " " }))
                lines[i] = "\(indent)\(key) \(value)"
                break
            }
            if inS && !line.hasPrefix("    ") && !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
        }
        writeConfig(lines.joined(separator: "\n"))
    }

    /// Returns true if osascript exited successfully (user granted permission)
    @discardableResult
    private func runPrivilegedSync(_ command: String) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func randomHex(_ bytes: Int) -> String {
        var data = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &data)
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

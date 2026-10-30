// Agent Command Center: a Dock + menu-bar app for local tmux and Copilot CLI sessions.
//
// The app bundles app.py (the tmux logic + JSON API) and ui.html. On launch it:
//  - keeps per-user data in ~/Library/Application Support/Agent Command Center,
//  - starts app.py on a free localhost port and shows ui.html in a window,
//  - installs a LaunchAgent that runs `app.py --save-all` every minute
//    (app.py decides from settings whether a save is actually due).
import Cocoa
import ServiceManagement
import WebKit

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser.path
let appName = "Agent Command Center"
let dataDir = "\(home)/Library/Application Support/\(appName)"
let legacyDataDir = "\(home)/Library/Application Support/Tmux Manager"
let legacyAgentLabel = "com.tmuxmanager.autosave"
let snapDir = "\(dataDir)/snapshots"
let appPy = Bundle.main.path(forResource: "app", ofType: "py") ?? "\(home)/agent-command-center/app.py"
let agentLabel = "com.agentcommandcenter.autosave"
let agentPlist = "\(home)/Library/LaunchAgents/\(agentLabel).plist"
let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

struct Session: Decodable { let name: String; let windows: Int; let attached: Bool; let rss: Int? }
struct Snapshot: Decodable {
    let file: String; let session: String; let saved_at: Double
    let auto: Bool?; let copilot: [String]?
}
struct Settings: Decodable { let terminal: String? }
struct CopilotLive: Decodable { let id: String; let title: String; let rss: Int; let tmux: String; let app: String }
struct Copilot: Decodable { let running: [CopilotLive] }
struct State: Decodable {
    let sessions: [Session]; let snapshots: [Snapshot]; let tmux: String?
    let settings: Settings?; let copilot: Copilot?
}

func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func asQuote(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
func humanSize(_ b: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
}

@discardableResult
func runTool(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out)
}

/// A python3 that actually works. /usr/bin/python3 is only a stub until the
/// Command Line Tools are installed, so it counts only when xcode-select is set up.
func findPython() -> String? {
    for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] where fm.isExecutableFile(atPath: p) {
        return p
    }
    if runTool("/usr/bin/xcode-select", ["-p"]).0 == 0, fm.isExecutableFile(atPath: "/usr/bin/python3") {
        return "/usr/bin/python3"
    }
    return nil
}

func freePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
    }
    _ = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    return Int(UInt16(bigEndian: addr.sin_port))
}

/// Invisible strip over the top of the window so it can still be dragged and
/// double-clicked to zoom, since the web view fills the title bar area.
final class DragStrip: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKUIDelegate, WKScriptMessageHandler {
    var item: NSStatusItem!
    var server: Process?
    var python: String?
    var port = 0
    var window: NSWindow?
    var webView: WKWebView?
    var base: String { "http://127.0.0.1:\(port)" }

    func applicationDidFinishLaunching(_ n: Notification) {
        migrateLegacy()
        try? fm.createDirectory(atPath: snapDir, withIntermediateDirectories: true)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Logo.menuBarImage()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        python = findPython()
        if python == nil {
            openWindow()
            return
        }
        startServer()
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            fail("Move \(appName) to your Applications folder, then open it again.\n\nmacOS is running it from a temporary location, so background auto-save can't be set up yet.")
        } else {
            installAgent()
            firstRunSetup()
        }
        openWindow()
    }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openWindow()
        return false
    }

    func applicationWillTerminate(_ n: Notification) { server?.terminate() }

    // MARK: setup

    func startServer() {
        guard let python = python else { return }
        port = freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [appPy, "--port", String(port)]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["TMUX_MANAGER_HOME"] = dataDir
        p.environment = env
        let log = "\(dataDir)/server.log"
        fm.createFile(atPath: log, contents: nil)
        p.standardOutput = FileHandle(forWritingAtPath: log)
        p.standardError = p.standardOutput
        do { try p.run() } catch { return fail("Could not start the background helper: \(error)") }
        server = p
        for _ in 0..<50 where !serverUp() { Thread.sleep(forTimeInterval: 0.1) }
    }

    func ensureServer() {
        if python != nil && (server?.isRunning != true || !serverUp()) {
            server?.terminate()
            startServer()
        }
    }

    /// Writes the auto-save LaunchAgent for this copy of the app and (re)loads it if it changed.
    func installAgent() {
        guard let python = python else { return }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [python, appPy, "--save-all"],
            "EnvironmentVariables": ["PATH": searchPath, "TMUX_MANAGER_HOME": dataDir],
            "StartInterval": 60,
            "RunAtLoad": true,
            "StandardOutPath": "\(dataDir)/autosave.log",
            "StandardErrorPath": "\(dataDir)/autosave.log",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return }
        let domain = "gui/\(getuid())"
        let loaded = runTool("/bin/launchctl", ["print", "\(domain)/\(agentLabel)"]).0 == 0
        if fm.contents(atPath: agentPlist) == data && loaded { return }
        try? fm.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
        fm.createFile(atPath: agentPlist, contents: data)
        if loaded { runTool("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"]) }
        runTool("/bin/launchctl", ["bootstrap", domain, agentPlist])
    }

    /// Carries data over from when this app was called "Tmux Manager" and removes its old job.
    func migrateLegacy() {
        if !fm.fileExists(atPath: dataDir), fm.fileExists(atPath: legacyDataDir) {
            try? fm.moveItem(atPath: legacyDataDir, toPath: dataDir)
        }
        let old = "\(home)/Library/LaunchAgents/\(legacyAgentLabel).plist"
        if fm.fileExists(atPath: old) {
            runTool("/bin/launchctl", ["bootout", "gui/\(getuid())/\(legacyAgentLabel)"])
            try? fm.removeItem(atPath: old)
        }
    }

    func firstRunSetup() {
        let key = "didFirstRunSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()  // open at login; can be turned off in Settings
    }

    var loginItemOn: Bool { SMAppService.mainApp.status == .enabled }

    // MARK: API

    func request(_ path: String, body: [String: Any]? = nil, timeout: Double = 3) -> (Int, Data?) {
        guard port > 0, let url = URL(string: base + path) else { return (0, nil) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if let body = body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("1", forHTTPHeaderField: "X-Tmux-Manager")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        var result: (Int, Data?) = (0, nil)
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            result = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return result
    }

    func serverUp() -> Bool { request("/api/state", timeout: 1).0 == 200 }

    func state() -> State? {
        ensureServer()
        let (code, data) = request("/api/state")
        guard code == 200, let data = data else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    @discardableResult
    func post(_ route: String, _ body: [String: Any]) -> [String: Any]? {
        let (code, data) = request("/api/" + route, body: body, timeout: 30)
        let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if code == 200 { webView?.evaluateJavaScript("refresh&&refresh()"); return obj ?? [:] }
        fail((obj?["error"] as? String) ?? "Something went wrong (\(code)).")
        return nil
    }

    // MARK: menu bar

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(action("Open \(appName)", #selector(openWindow), keyEquivalent: "o"))
        menu.addItem(.separator())
        guard let st = state() else {
            menu.addItem(disabled(python == nil ? "Python 3 is not installed" : "Helper not responding"))
            addFooter(menu)
            return
        }
        if st.tmux == nil { menu.addItem(disabled("tmux is not installed (brew install tmux)")) }
        menu.addItem(disabled(st.sessions.isEmpty ? "No sessions running" : "Sessions"))
        for s in st.sessions {
            let mem = s.rss.map { " · \(humanSize($0))" } ?? ""
            let it = NSMenuItem(title: "\(s.attached ? "●" : "○")  \(s.name)\(mem)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(action("Attach", #selector(attach(_:)), s.name))
            sub.addItem(action("Save", #selector(save(_:)), s.name))
            sub.addItem(action("Save & Close", #selector(saveKill(_:)), s.name))
            it.submenu = sub
            menu.addItem(it)
        }
        menu.addItem(action("Save All", #selector(saveAll), keyEquivalent: "s"))
        menu.addItem(.separator())
        terminalPref = st.settings?.terminal ?? "auto"

        let cps = st.copilot?.running ?? []
        menu.addItem(disabled(cps.isEmpty ? "No Copilot sessions running"
            : "Copilot · \(cps.count) running · \(humanSize(cps.reduce(0) { $0 + $1.rss }))"))
        for c in cps {
            let where_ = c.tmux.isEmpty ? (c.app.isEmpty ? "terminal" : c.app) : "tmux: \(c.tmux)"
            let it = action("✦  \(c.title.isEmpty ? "Untitled session" : c.title) · \(where_) · \(humanSize(c.rss))",
                            #selector(openCopilotTab))
            menu.addItem(it)
        }
        menu.addItem(.separator())

        let running = Set(st.sessions.map(\.name))
        var latest: [String: Snapshot] = [:]
        for s in st.snapshots where latest[s.session] == nil { latest[s.session] = s }
        let restore = NSMenuItem(title: "Restore", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        for s in latest.values.sorted(by: { $0.saved_at > $1.saved_at }) {
            var title = "\(s.session) — \(fmt.localizedString(for: Date(timeIntervalSince1970: s.saved_at), relativeTo: Date()))"
            if let cp = s.copilot, !cp.isEmpty { title += " · ✦ \(cp.joined(separator: ", "))" }
            let i = action(title, #selector(restore(_:)), s.file)
            if running.contains(s.session) { i.action = nil; i.title += "  (running)" }
            sub.addItem(i)
        }
        if latest.isEmpty { sub.addItem(disabled("No snapshots yet")) }
        restore.submenu = sub
        menu.addItem(restore)
        addFooter(menu)
    }

    func addFooter(_ menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), keyEquivalent: ","))
        menu.addItem(action("Quit", #selector(quit), keyEquivalent: "q"))
    }

    func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func action(_ t: String, _ sel: Selector, _ obj: Any? = nil, keyEquivalent: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: keyEquivalent)
        i.target = self
        i.representedObject = obj
        return i
    }

    @objc func save(_ s: NSMenuItem) { post("save", ["name": s.representedObject as! String]) }
    @objc func saveKill(_ s: NSMenuItem) { post("savekill", ["name": s.representedObject as! String]) }
    @objc func saveAll() { post("saveall", [:]) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func attach(_ s: NSMenuItem) { attachSession(s.representedObject as! String) }
    @objc func restore(_ s: NSMenuItem) {
        if let r = post("restore", ["file": s.representedObject as! String]), let name = r["name"] as? String {
            attachSession(name)
        }
    }
    @objc func openSettings() { openWindow(); webView?.evaluateJavaScript("show('settings')") }
    @objc func openCopilotTab() { openWindow(); webView?.evaluateJavaScript("show('copilot')") }

    var terminalPref = "auto"

    func attachSession(_ name: String) { openTerminal("tmux attach -t \(shQuote("=" + name))", terminalPref) }

    func copyText(_ t: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    /// Runs `cmd` in a new terminal window. "auto" uses iTerm only if it is already
    /// running (launching it is slow and can fail), otherwise Terminal. "copy" just
    /// copies it, for terminals that can't be scripted (Termius, Warp…).
    /// AppleScript runs off the main thread so a stuck terminal can't freeze the app.
    func openTerminal(_ cmd: String, _ pref: String) {
        if pref == "copy" {
            copyText(cmd)
            let a = NSAlert()
            a.messageText = "Command copied"
            a.informativeText = "Paste it into your terminal:\n\n\(cmd)"
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
            return
        }
        let itermID = "com.googlecode.iterm2"
        let useITerm = pref == "iterm"
            || (pref == "auto" && !NSRunningApplication.runningApplications(withBundleIdentifier: itermID).isEmpty)
        let script = useITerm
            ? "tell application \"iTerm\"\nactivate\nset w to (create window with default profile)\ntell current session of w to write text \(asQuote(cmd))\nend tell"
            : "tell application \"Terminal\"\nactivate\ndo script \(asQuote(cmd))\nend tell"
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: "with timeout of 15 seconds\n\(script)\nend timeout")?.executeAndReturnError(&err)
            if let err = err {
                DispatchQueue.main.async {
                    self.copyText(cmd)
                    self.fail("Couldn't open \(useITerm ? "iTerm" : "Terminal"): \(err[NSAppleScript.errorMessage] ?? "unknown error").\n\nThe command was copied instead:\n\(cmd)\n\nYou can pick another terminal in Settings.")
                }
            }
        }
    }

    // MARK: window

    @objc func openWindow() {
        if window == nil {
            let cfg = WKWebViewConfiguration()
            cfg.userContentController.add(self, name: "tm")
            let wv = WKWebView(frame: .zero, configuration: cfg)
            wv.uiDelegate = self
            wv.setValue(false, forKey: "drawsBackground")
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = appName
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            // Translucent sidebar material shows through the page's transparent sidebar.
            let blur = NSVisualEffectView()
            blur.material = .sidebar
            blur.blendingMode = .behindWindow
            blur.state = .followsWindowActiveState
            wv.autoresizingMask = [.width, .height]
            if #available(macOS 12.0, *) { wv.underPageBackgroundColor = .clear }
            blur.addSubview(wv)
            let drag = DragStrip()
            drag.autoresizingMask = [.width, .minYMargin]
            blur.addSubview(drag)
            w.contentView = blur
            wv.frame = blur.bounds
            drag.frame = NSRect(x: 0, y: blur.bounds.height - 28, width: blur.bounds.width, height: 28)
            w.minSize = NSSize(width: 760, height: 520)
            w.center()
            w.setFrameAutosaveName("AgentCommandCenterWindow")
            window = w
            webView = wv
        }
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.TM_NATIVE={loginItem:\(loginItemOn)}",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if python == nil {
            webView?.loadHTMLString(setupPage, baseURL: nil)
        } else {
            ensureServer()
            webView?.load(URLRequest(url: URL(string: base + "/")!))
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    let setupPage = """
    <html><body style="font:15px -apple-system;padding:60px;color:#888;text-align:center">
    <h2 style="color:inherit">Python 3 is needed</h2>
    <p>\(appName) uses the Python that comes with Apple's Command Line Tools.</p>
    <p>Run <code>xcode-select --install</code> in Terminal (or <code>brew install python tmux</code>),<br>then open \(appName) again.</p>
    </body></html>
    """

    // Messages from ui.html: {action: "terminal"|"folder"|"login", ...}
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let act = m["action"] as? String else { return }
        switch act {
        case "terminal":
            if let cmd = m["command"] as? String { openTerminal(cmd, m["app"] as? String ?? "auto") }
        case "copy":
            if let t = m["text"] as? String { copyText(t) }
        case "folder":
            NSWorkspace.shared.open(URL(fileURLWithPath: snapDir))
        case "login":
            do {
                if m["on"] as? Bool == true { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch { fail("Could not change the login item: \(error.localizedDescription)") }
        default: break
        }
    }

    // MARK: dialogs

    func fail(_ msg: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = appName
        a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String,
                 initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping () -> Void) {
        fail(m); done()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

let mainMenu = NSMenu()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(.separator())
let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
settingsItem.target = delegate
appMenu.addItem(.separator())
appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let appMenuItem = NSMenuItem()
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)
let editMenu = NSMenu(title: "Edit")
for (t, s, k) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                  ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
    editMenu.addItem(withTitle: t, action: Selector(s), keyEquivalent: k)
}
let editItem = NSMenuItem()
editItem.submenu = editMenu
mainMenu.addItem(editItem)
let windowMenu = NSMenu(title: "Window")
windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
let windowItem = NSMenuItem()
windowItem.submenu = windowMenu
mainMenu.addItem(windowItem)
app.mainMenu = mainMenu
app.run()

// Setup / uninstall UI, shown when the user opens "PeriPage Bridge.app" directly.
import AppKit
import CoreBluetooth

let agentLabel = "local.peripage.bridge"
let queueName = "PeriPage_P81_Bluetooth"
let queueTitle = "PeriPage P81 (Bluetooth)"
let ppdPath = "/Library/Printers/iLeadtek/PPDs/PPG P81 SD.ppd"
let home = FileManager.default.homeDirectoryForCurrentUser.path
let installedApp = "\(home)/Applications/PeriPage Bridge.app"
let agentPlist = "\(home)/Library/LaunchAgents/\(agentLabel).plist"

@discardableResult
func sh(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    p.waitUntilExit()
    return (p.terminationStatus, out)
}

func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Runs a shell command as root via the standard macOS password prompt.
func runAsAdmin(_ cmd: String, prompt: String) -> Bool {
    let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let src = "do shell script \"\(esc)\" with prompt \"\(prompt)\" with administrator privileges"
    var err: NSDictionary?
    NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err = err { log("admin command failed: \(err)"); return false }
    return true
}

@discardableResult
func alert(_ title: String, _ text: String, buttons: [String] = ["OK"], style: NSAlert.Style = .informational) -> Int {
    let a = NSAlert()
    a.messageText = title; a.informativeText = text; a.alertStyle = style
    for b in buttons { a.addButton(withTitle: b) }
    NSApp.activate(ignoringOtherApps: true)
    return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
}

func queueExists() -> Bool { sh("/usr/bin/lpstat", ["-p", queueName]).0 == 0 }
func isInstalled() -> Bool {
    FileManager.default.fileExists(atPath: ppdPath) && FileManager.default.fileExists(atPath: agentPlist)
        && FileManager.default.fileExists(atPath: installedApp) && queueExists()
}

/// Waits (pumping the run loop) for the user to answer the Bluetooth permission prompt.
final class BTPermission: NSObject, CBCentralManagerDelegate {
    var cm: CBCentralManager?
    var decided = false
    func request() -> CBManagerAuthorization {
        if CBCentralManager.authorization != .notDetermined { return CBCentralManager.authorization }
        cm = CBCentralManager(delegate: self, queue: .main)
        let deadline = Date().addingTimeInterval(120)
        while !decided && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        return CBCentralManager.authorization
    }
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if CBCentralManager.authorization != .notDetermined { decided = true }
    }
}

/// Official PeriPage (Xiamen iLeadtek) P81 macOS driver.
let driverURL = "https://cdn.ileadtek.com/resource/www/drive/cn/p81/Mac_P81_PC_Driver_V1.2.1.66.zip"
/// Apple Developer Team ID that signs the official driver installer.
let driverTeamID = "DHXV3VSRNJ"

/// Downloads the official driver and returns the path to its installer package,
/// only if the package is signed by the manufacturer's Developer ID.
func downloadDriver() -> String? {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("peripage-driver-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let zip = tmp.appendingPathComponent("driver.zip")
    log("downloading driver from \(driverURL)")
    let (rc, out) = sh("/usr/bin/curl", ["-fsSL", "--max-time", "300", "-o", zip.path, driverURL])
    guard rc == 0 else { log("driver download failed: \(out)"); return nil }
    let dir = tmp.appendingPathComponent("x")
    guard sh("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]).0 == 0 else { return nil }
    let e = FileManager.default.enumerator(atPath: dir.path)
    while let f = e?.nextObject() as? String {
        guard f.hasSuffix(".pkg") else { continue }
        let pkg = dir.appendingPathComponent(f).path
        let (sigRC, sig) = sh("/usr/sbin/pkgutil", ["--check-signature", pkg])
        if sigRC == 0 && sig.contains("(\(driverTeamID))") && sig.contains("Notarization: trusted") { return pkg }
        log("driver package signature not trusted: \(sig)")
        return nil
    }
    return nil
}

func stopAgent() { sh("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"]) }

func install() -> Bool {
    let fm = FileManager.default

    // 1. Put the app in ~/Applications (the login agent needs a stable path).
    let me = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    stopAgent()
    if me != installedApp {
        try? fm.createDirectory(atPath: "\(home)/Applications", withIntermediateDirectories: true)
        if fm.fileExists(atPath: installedApp) { try? fm.removeItem(atPath: installedApp) }
        do { try fm.copyItem(atPath: me, toPath: installedApp) }
        catch { alert("Couldn't copy the app", "\(error.localizedDescription)", style: .critical); return false }
        sh("/usr/bin/xattr", ["-dr", "com.apple.quarantine", installedApp])
    }

    // 2. Official PeriPage driver, needs an admin password once.
    //    Uses a copy bundled in the app if present, otherwise downloads it from the manufacturer.
    if !fm.fileExists(atPath: ppdPath) {
        let bundled = Bundle(path: installedApp)?.path(forResource: "PeriPage-P81-Driver", ofType: "pkg")
        guard let pkg = bundled ?? downloadDriver() else {
            alert("Driver not available",
                  "Couldn't download the PeriPage P81 driver. Check your internet connection and try again, or install it manually from \(driverURL).",
                  style: .critical)
            return false
        }
        let ok = runAsAdmin("/usr/sbin/installer -pkg \(shQuote(pkg)) -target /",
                            prompt: "PeriPage Bridge wants to install the PeriPage P81 printer driver.")
        guard ok, fm.fileExists(atPath: ppdPath) else {
            alert("Driver not installed", "The PeriPage driver installation was cancelled or failed.", style: .warning); return false
        }
    }

    // 3. Bluetooth permission.
    let auth = BTPermission().request()
    if auth == .denied || auth == .restricted {
        alert("Bluetooth access needed",
              "Turn on PeriPage Bridge in System Settings → Privacy & Security → Bluetooth, then open this app again.",
              style: .warning)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth")!)
    }

    // 4. Printer queue (socket to the local bridge, official SD driver = correct proportions).
    sh("/usr/sbin/lpadmin", ["-x", queueName])
    let args = ["-p", queueName, "-D", queueTitle, "-L", "Bluetooth via PeriPage Bridge",
                "-v", "socket://127.0.0.1:9181", "-P", ppdPath,
                "-o", "PageSize=w595h841", "-o", "printer-is-shared=false", "-E"]
    if sh("/usr/sbin/lpadmin", args).0 != 0 || !queueExists() {
        let cmd = "/usr/sbin/lpadmin " + args.map(shQuote).joined(separator: " ")
        _ = runAsAdmin(cmd, prompt: "PeriPage Bridge wants to add the printer \"\(queueTitle)\".")
    }
    guard queueExists() else { alert("Printer not added", "Couldn't add the printer queue.", style: .critical); return false }

    // 5. Login agent that runs the bridge in the background.
    let exe = "\(installedApp)/Contents/MacOS/PeriPageBridge"
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [exe],
        "EnvironmentVariables": ["PERIPAGE_AGENT": "1"],
        "AssociatedBundleIdentifiers": [agentLabel],
        "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Interactive",
    ]
    try? fm.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
    do {
        let d = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try d.write(to: URL(fileURLWithPath: agentPlist))
    } catch { alert("Couldn't create the login item", "\(error.localizedDescription)", style: .critical); return false }
    let (rc, out) = sh("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist])
    if rc != 0 { log("bootstrap failed: \(out)") }
    return true
}

func uninstall() {
    stopAgent()
    try? FileManager.default.removeItem(atPath: agentPlist)
    sh("/usr/sbin/lpadmin", ["-x", queueName])
    if FileManager.default.fileExists(atPath: installedApp) {
        NSWorkspace.shared.recycle([URL(fileURLWithPath: installedApp)]) { _, _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }
}

func runSetup() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    if isInstalled() {
        let r = alert("PeriPage Bluetooth printing is set up",
                      "Print from any app to “\(queueTitle)”.\n\nKeep the printer on and the PeriPage iPhone app disconnected while printing.",
                      buttons: ["OK", "Repair", "Uninstall"])
        if r == 1 {
            if install() { alert("Repaired", "Everything has been reinstalled.") }
        } else if r == 2 {
            if alert("Uninstall PeriPage Bluetooth printing?",
                     "This removes the printer and the background helper. The PeriPage driver stays installed.",
                     buttons: ["Uninstall", "Cancel"], style: .warning) == 0 {
                uninstall(); alert("Uninstalled", "PeriPage Bluetooth printing has been removed.")
            }
        }
        exit(0)
    }

    let r = alert("Set up PeriPage P81 Bluetooth printing?",
                  "This will:\n• download and install the official PeriPage P81 driver (asks for your password)\n• add the printer “\(queueTitle)”\n• run a small background helper that sends print jobs over Bluetooth\n\nYou'll be asked to allow Bluetooth access.",
                  buttons: ["Set Up", "Cancel"])
    guard r == 0 else { exit(0) }
    if install() {
        alert("You're all set",
              "Print from any app (File → Print) and choose “\(queueTitle)”.\n\nTurn the printer on and disconnect the PeriPage iPhone app before printing. A page takes about 25 seconds.")
    }
    exit(0)
}

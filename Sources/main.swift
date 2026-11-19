// PeriPage Bridge
// Lets macOS print to a PeriPage P81 over Bluetooth LE.
//
// CUPS queue (socket://127.0.0.1:9181, official "PPG P81 SD" driver) renders each job
// into PeriPage printer commands and streams them here. We forward them to the printer
// over BLE (service FF00, write characteristic FF02) with the printer's flow control:
//   FF03 "01 NN"  -> NN more packets may be sent (credits)
//   FF03 "02 LL HH" -> printer max packet size
//   FF01 "4f 4b"  -> "OK" (setup command acknowledged)
//   FF01 "aa"     -> page finished
//   FF01 "ff 01"  -> paper out / sheet ended
// The setup commands at the start of a job must be acknowledged before the image is
// sent, otherwise the printer drops the first bytes and every row shifts sideways.

import Foundation
import CoreBluetooth
import Network

let port: NWEndpoint.Port = 9181
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/PeriPageBridge.log")

func log(_ s: String) {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date())) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.data(using: .utf8)!.write(to: logURL) }
}

func notify(_ msg: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let esc = msg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    p.arguments = ["-e", "display notification \"\(esc)\" with title \"PeriPage Bluetooth\""]
    try? p.run()
}

// MARK: - Job segmentation

enum Wait { case none, setupOK, pageDone }
struct Segment { let range: Range<Int>; let waitAfter: Wait }

func find(_ b: [UInt8], _ pat: [UInt8], from: Int) -> Int? {
    guard b.count >= pat.count, from <= b.count - pat.count else { return nil }
    var i = from
    while i <= b.count - pat.count {
        if b[i] == pat[0] && Array(b[i..<(i + pat.count)]) == pat { return i }
        i += 1
    }
    return nil
}

/// Split the stream: [setup] wait OK, [page 1 ... page end] wait page done, [page 2 ...] ...
func segments(_ d: Data) -> [Segment] {
    let b = [UInt8](d)
    var segs: [Segment] = []
    var start = 0
    if let r = find(b, [0x1d, 0x76, 0x30], from: 0), r > 0 {
        segs.append(Segment(range: 0..<r, waitAfter: .setupOK)); start = r
    }
    var p = start
    while p < b.count {
        // walk raster blocks precisely so image bytes are never mistaken for commands
        if p + 8 <= b.count, b[p] == 0x1d, b[p+1] == 0x76, b[p+2] == 0x30 {
            let w = Int(b[p+4]) | Int(b[p+5]) << 8, h = Int(b[p+6]) | Int(b[p+7]) << 8
            p = min(b.count, p + 8 + w * h); continue
        }
        if p + 4 <= b.count, b[p] == 0x10, b[p+1] == 0xff, b[p+2] == 0xfe, b[p+3] == 0x45 {
            let end = p + 4
            if end < b.count { segs.append(Segment(range: start..<end, waitAfter: .pageDone)); start = end }
            p = end; continue
        }
        p += 1
    }
    if start < b.count { segs.append(Segment(range: start..<b.count, waitAfter: .none)) }
    return segs
}

// MARK: - BLE job

final class BLEJob: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let svc = CBUUID(string: "FF00"), wrUUID = CBUUID(string: "FF02"), creditUUID = CBUUID(string: "FF03")
    let data: Data
    let segs: [Segment]
    let done: (Bool) -> Void
    var cm: CBCentralManager!
    var per: CBPeripheral?
    var wr: CBCharacteristic?
    var seg = 0, off = 0
    var chunk = 240, credits = 0, oks = 0, pagesDone = 0
    var waiting = false, finished = false, started = false
    var lastProgress = Date()
    var watchdog: Timer?

    init(data: Data, done: @escaping (Bool) -> Void) {
        self.data = data; self.segs = segments(data); self.done = done
        super.init()
        cm = CBCentralManager(delegate: self, queue: .main)
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        log("job: \(data.count) bytes, \(segs.count) segments")
    }

    func tick() {
        guard !finished else { return }
        let idle = Date().timeIntervalSince(lastProgress)
        if per == nil && idle > 20 {
            fail("PeriPage not found. Turn it on and disconnect the iPhone app, then print again.")
        } else if idle > 300 {
            fail("Printing stalled. Check the printer and paper, then print again.")
        }
    }

    func fail(_ msg: String) {
        guard !finished else { return }
        log("FAIL: \(msg)"); notify(msg); finish(false)
    }

    func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true; watchdog?.invalidate()
        if let p = per { cm.cancelPeripheralConnection(p) }
        cm.stopScan()
        DispatchQueue.main.async { self.done(ok) }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: c.scanForPeripherals(withServices: [Self.svc])
        case .unauthorized: fail("Bluetooth permission denied. Allow PeriPage Bridge in System Settings → Privacy & Security → Bluetooth.")
        case .poweredOff: fail("Bluetooth is off.")
        default: break
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard per == nil, !finished else { return }
        per = p; p.delegate = self; c.stopScan(); c.connect(p)
        lastProgress = Date(); log("connecting to \(p.name ?? "printer")")
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([Self.svc]) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { fail("Couldn't connect to the PeriPage.") }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if !finished { fail("PeriPage disconnected during printing.") }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
            if ch.uuid == Self.wrUUID { wr = ch }
        }
        guard wr != nil else { fail("Printer doesn't expose the expected data channel."); return }
        chunk = min(p.maximumWriteValueLength(for: .withoutResponse), chunk)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.started = true; self.pump() }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let v = [UInt8](ch.value ?? Data())
        if ch.uuid == Self.creditUUID {
            if v.count >= 2, v[0] == 0x01 { credits += Int(v[1]); pump() }
            else if v.count >= 3, v[0] == 0x02 { chunk = max(20, min(chunk, Int(v[1]) | Int(v[2]) << 8)) }
            return
        }
        lastProgress = Date()
        if v == [0x4f, 0x4b] { oks += 1 }
        else if v == [0xaa] { pagesDone += 1 }
        else if v == [0xff, 0x01] { notify("Load paper into the PeriPage to continue."); log("printer: paper out") }
        else { log("printer status: \(v.map { String(format: "%02x", $0) }.joined(separator: " "))") }
    }
    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) { pump() }

    func pump() {
        guard started, !finished, !waiting, let p = per, let wr = wr else { return }
        while seg < segs.count {
            let r = segs[seg].range
            if off < r.lowerBound { off = r.lowerBound }
            while off < r.upperBound && credits > 0 && p.canSendWriteWithoutResponse {
                credits -= 1
                let end = min(off + chunk, r.upperBound)
                p.writeValue(data.subdata(in: off..<end), for: wr, type: .withoutResponse)
                off = end; lastProgress = Date()
            }
            if off < r.upperBound { return } // wait for credits / BLE buffer
            let w = segs[seg].waitAfter
            seg += 1
            if w != .none { waitFor(w); return }
        }
        log("job sent, waiting for printer to finish")
        // wait for the final "page done" (or 15s) before disconnecting
        let target = pagesDone + 1
        func check(_ n: Int) {
            if self.pagesDone >= target || n >= 150 { self.log2done() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check(n + 1) } }
        }
        waiting = true; check(0)
    }
    func log2done() { log("job complete"); finish(true) }

    func waitFor(_ w: Wait) {
        waiting = true
        let okTarget = 2, pageTarget = pagesDone + 1
        let t0 = Date()
        func check() {
            guard !self.finished else { return }
            let ready: Bool
            switch w {
            case .setupOK: ready = self.oks >= okTarget || Date().timeIntervalSince(t0) > 3
            case .pageDone: ready = self.pagesDone >= pageTarget || Date().timeIntervalSince(t0) > 240
            case .none: ready = true
            }
            if ready {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.waiting = false; self.lastProgress = Date(); self.pump() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
            }
        }
        check()
    }
}

// MARK: - Local socket server (CUPS socket:// backend connects here)

final class Server {
    var listener: NWListener!
    var queue: [(Data, NWConnection)] = []
    var current: BLEJob?

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.stateUpdateHandler = { s in log("listener: \(s)") }
        listener.start(queue: .main)
    }

    func accept(_ c: NWConnection) {
        var buf = Data()
        c.start(queue: .main)
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, isComplete, err in
                if let d = d { buf.append(d) }
                if isComplete || err != nil {
                    if buf.isEmpty { c.cancel(); return }
                    self.queue.append((buf, c)); self.next()
                } else { read() }
            }
        }
        read()
    }

    func next() {
        guard current == nil, !queue.isEmpty else { return }
        let (d, c) = queue.removeFirst()
        current = BLEJob(data: d) { [weak self] _ in
            c.cancel()           // closing the socket tells CUPS the job is finished
            self?.current = nil
            self?.next()
        }
    }
}

// Touch Bluetooth once at launch so macOS asks for permission up front.
final class Probe: NSObject, CBCentralManagerDelegate {
    var cm: CBCentralManager!
    override init() { super.init(); cm = CBCentralManager(delegate: self, queue: .main) }
    func centralManagerDidUpdateState(_ c: CBCentralManager) { log("bluetooth state: \(c.state.rawValue)") }
}

var server: Server?
var probe: Probe?

func runBridge() -> Never {
    log("PeriPage Bridge starting on 127.0.0.1:\(port)")
    server = Server()
    do { try server!.start() } catch { log("listen failed: \(error)"); exit(1) }
    probe = Probe()
    RunLoop.main.run()
    exit(0)
}

// Launched by the login agent -> run the print bridge.
// Opened by the user (double-click) -> run setup / uninstall.
if ProcessInfo.processInfo.environment["PERIPAGE_AGENT"] == "1" {
    runBridge()
} else {
    runSetup()
}

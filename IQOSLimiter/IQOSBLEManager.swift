import CoreBluetooth
import Combine
import UserNotifications

// ── IQOS BLE Protocol Constants ───────────────────────────────────────────────
// Βασισμένο στο https://github.com/hauntedfail/iqos (GPL-3.0)

private let kIQOSCoreServiceUUID     = CBUUID(string: "daebb240-b041-11e4-9e45-0002a5d5c51b")
private let kSCPControlCharUUID      = CBUUID(string: "daebb241-b041-11e4-9e45-0002a5d5c51b")
private let kILUMAControlCharUUID    = CBUUID(string: "e16c6e20-b041-11e4-a4c3-0002a5d5c51b")
private let kSCPNotifyCharUUID       = CBUUID(string: "daebb242-b041-11e4-9e45-0002a5d5c51b")

// CRC8 SMBus Checksum Generator (Poly 0x07)
func calcCRC8SMBus(_ bytes: Data) -> UInt8 {
    var crc: UInt8 = 0
    for b in bytes {
        crc ^= b
        for _ in 0..<8 {
            if (crc & 0x80) != 0 {
                crc = ((crc << 1) ^ 0x07)
            } else {
                crc = (crc << 1)
            }
        }
    }
    return crc
}

func buildIQOSCommand(opcode: UInt8, reg: [UInt8], payload: [UInt8]) -> Data {
    var data = Data([0x00, opcode])
    let body = Data(reg + [UInt8(payload.count)] + payload)
    let crc = calcCRC8SMBus(body)
    data.append(body)
    data.append(crc)
    return data
}

// Telemetry command (puff count)
private let kTelemetryCmd   = Data([0x00, 0xC9, 0x10, 0x02, 0x01, 0x01, 0x75, 0xD6])
// Lock sequence
private let kLockCmd1       = Data([0x00, 0xC9, 0x44, 0x04, 0x02, 0xFF, 0x00, 0x00, 0x5A])
private let kLockCmd2       = Data([0x00, 0xC9, 0x00, 0x04, 0x1C])
// Unlock sequence
private let kUnlockCmd1     = Data([0x00, 0xC9, 0x44, 0x04, 0x00, 0x00, 0x00, 0x00, 0x5D])
private let kUnlockCmd2     = Data([0x00, 0xC9, 0x00, 0x04, 0x1C])

// Captured ILUMA commands
private let kPauseModeOnCmd  = buildIQOSCommand(opcode: 0xD2, reg: [0x45, 0x22], payload: [0x01, 0x00, 0x00])
private let kPauseModeOffCmd = buildIQOSCommand(opcode: 0xD2, reg: [0x45, 0x22], payload: [0x00, 0x00, 0x00])

// Telemetry response header (bytes[2..4])
private let kTelemetryHeader: [UInt8] = [0x90, 0x22]
private let kTagPuffCount: UInt8      = 0x8E

// ── Daily State (UserDefaults) ────────────────────────────────────────────────
struct DailyState {
    static let keyDate          = "iqos.date"
    static let keyBaseline      = "iqos.baseline"
    static let keyPuffsToday    = "iqos.puffsToday"
    static let keyLocked        = "iqos.locked"

    static var today: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    static func resetIfNewDay() {
        let ud = UserDefaults.standard
        if ud.string(forKey: keyDate) != today {
            ud.set(today, forKey: keyDate)
            ud.removeObject(forKey: keyBaseline)
            ud.set(0, forKey: keyPuffsToday)
            ud.set(false, forKey: keyLocked)
        }
    }

    static var baseline: Int? {
        get {
            let v = UserDefaults.standard.integer(forKey: keyBaseline)
            return UserDefaults.standard.object(forKey: keyBaseline) == nil ? nil : v
        }
        set { UserDefaults.standard.set(newValue, forKey: keyBaseline) }
    }

    static var puffsToday: Int {
        get { UserDefaults.standard.integer(forKey: keyPuffsToday) }
        set { UserDefaults.standard.set(newValue, forKey: keyPuffsToday) }
    }

    static var locked: Bool {
        get { UserDefaults.standard.bool(forKey: keyLocked) }
        set { UserDefaults.standard.set(newValue, forKey: keyLocked) }
    }
}

// ── BLE Manager ───────────────────────────────────────────────────────────────
enum ConnectionState {
    case idle, scanning, connecting, connected, disconnected
    var label: String {
        switch self {
        case .idle:          return "Σε αναμονή"
        case .scanning:      return "Σάρωση..."
        case .connecting:    return "Σύνδεση..."
        case .connected:     return "Συνδεδεμένο ✓"
        case .disconnected:  return "Αποσυνδέθηκε"
        }
    }
}

class IQOSBLEManager: NSObject, ObservableObject {

    // ── Published state ───────────────────────────────────────────────────────
    @Published var connectionState: ConnectionState = .idle
    @Published var puffsToday: Int    = DailyState.puffsToday
    @Published var dailyLimit: Int    = UserDefaults.standard.object(forKey: "iqos.limit") == nil
                                            ? 5
                                            : UserDefaults.standard.integer(forKey: "iqos.limit")
    @Published var isLocked: Bool     = DailyState.locked
    @Published var statusMessage: String = "Άνοιξε την εφαρμογή για να ξεκινήσει"
    @Published var lifetimePuffs: Int = 0

    // ── Private BLE state ─────────────────────────────────────────────────────
    private var centralManager: CBCentralManager!
    private var iqosPeripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    // Continuations για async/await command responses
    private var pendingResponse: CheckedContinuation<Data, Error>?
    private var reconnectTimer: Timer?
    private var pollingTimer: Timer?

    override init() {
        super.init()
        DailyState.resetIfNewDay()
        centralManager = CBCentralManager(delegate: self, queue: .main,
                                          options: [CBCentralManagerOptionRestoreIdentifierKey: "iqos.restore"])
        requestNotificationPermission()
    }

    // ── Public API ────────────────────────────────────────────────────────────

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            statusMessage = "Ενεργοποίησε το Bluetooth"
            return
        }
        connectionState = .scanning
        statusMessage   = "Σάρωση για IQOS..."
        centralManager.scanForPeripherals(withServices: [kIQOSCoreServiceUUID],
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func setDailyLimit(_ limit: Int) {
        dailyLimit = limit
        UserDefaults.standard.set(limit, forKey: "iqos.limit")
        Task { await evaluateLimit() }
    }

    func manualLock() {
        Task { await sendLock() }
    }

    func manualUnlock() {
        Task { await sendUnlock() }
    }

    func manualRefresh() {
        Task { await evaluateLimit() }
    }

    // ── Polling Timer ─────────────────────────────────────────────────────────

    private func startPolling() {
        stopPolling()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { await self?.evaluateLimit() }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }


    // ── Protocol helpers ──────────────────────────────────────────────────────

    private func sendCommand(_ data: Data) async throws -> Data {
        guard let peripheral = iqosPeripheral,
              let char = controlChar,
              peripheral.state == .connected else {
            throw NSError(domain: "IQOSLimiter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Λείπει το κανάλι αποστολής εντολών (SCP Write)"])
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingResponse = continuation
            peripheral.writeValue(data, for: char, type: .withoutResponse)
        }
    }

    private func sendNoResponse(_ data: Data) {
        guard let peripheral = iqosPeripheral, let char = controlChar else { return }
        peripheral.writeValue(data, for: char, type: .withoutResponse)
    }

    // ── Telemetry ─────────────────────────────────────────────────────────────

    @MainActor
    private func readPuffCount() async -> Int? {
        guard controlChar != nil && notifyChar != nil else { return nil }

        do {
            let response = try await sendCommand(kTelemetryCmd)
            return parsePuffCount(from: response)
        } catch {
            statusMessage = "Σφάλμα ανάγνωσης: \(error.localizedDescription)"
            return nil
        }
    }

    private func parsePuffCount(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        // 1. Έλεγχος τυπικού SCP 8-byte block (tag 0x8E / 0x8F / 0x90)
        let payload = Array(bytes.dropFirst(4))
        let blockSize = 8
        var i = 0
        while i + blockSize <= payload.count {
            let block = Array(payload[i ..< i + blockSize])
            let tag   = block[7]
            if tag == kTagPuffCount || tag == 0x8E || tag == 0x8F || tag == 0x90 {
                let value = Int(block[4]) | (Int(block[5]) << 8)
                if value > 0 { return value }
            }
            i += blockSize
        }

        // 2. Smart Fallback: Εντοπισμός θετικού 16-bit little-endian ακεραίου στο payload
        for idx in stride(from: 2, to: bytes.count - 1, by: 2) {
            let val = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            if val >= 1 && val < 65000 {
                return val
            }
        }

        return nil
    }

    // ── Lock / Unlock ─────────────────────────────────────────────────────────

    @MainActor
    private func sendLock() async {
        sendNoResponse(kLockCmd1)
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        sendNoResponse(kLockCmd2)
        isLocked         = true
        DailyState.locked = true
        statusMessage     = "🔒 Κλειδωμένο — Επίτευξες το ημερήσιο όριο!"
        sendNotification(title: "IQOS Κλειδωμένο 🔒",
                         body: "Έφτασες τα \(dailyLimit) sticks για σήμερα. Καλή συνέχεια!")
    }

    @MainActor
    private func sendUnlock() async {
        sendNoResponse(kUnlockCmd1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        sendNoResponse(kUnlockCmd2)
        isLocked         = false
        DailyState.locked = false
        statusMessage     = "🔓 Ξεκλειδωμένο"
    }

    // ── Limit evaluation ──────────────────────────────────────────────────────

    @MainActor
    func evaluateLimit() async {
        guard let lifetimeCount = await readPuffCount() else { return }

        lifetimePuffs = lifetimeCount

        // Ορισμός baseline αν είναι πρώτη φορά σήμερα
        if DailyState.baseline == nil {
            DailyState.baseline = lifetimeCount
            statusMessage = "📌 Baseline: \(lifetimeCount) puffs"
        }

        let today = max(0, lifetimeCount - (DailyState.baseline ?? lifetimeCount))
        DailyState.puffsToday = today
        puffsToday = today

        let remaining = dailyLimit - today

        if today >= dailyLimit {
            statusMessage = "🚫 Όριο! \(today)/\(dailyLimit) sticks"
            if !isLocked { await sendLock() }
        } else {
            statusMessage = "✅ \(today)/\(dailyLimit) sticks — Απομένουν \(remaining)"
            if isLocked { await sendUnlock() }  // νέα μέρα, ξεκλείδωμα
        }
    }

    // ── Notifications ─────────────────────────────────────────────────────────

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        let content        = UNMutableNotificationContent()
        content.title      = title
        content.body       = body
        content.sound      = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // ── Auto-reconnect ────────────────────────────────────────────────────────

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.startScanning()
        }
    }
}

// ── CBCentralManagerDelegate ─────────────────────────────────────────────────
extension IQOSBLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanning()
        } else {
            statusMessage   = "Bluetooth απενεργοποιημένο"
            connectionState = .idle
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard iqosPeripheral == nil else { return }
        central.stopScan()
        iqosPeripheral  = peripheral
        connectionState = .connecting
        statusMessage   = "Σύνδεση με \(peripheral.name ?? "IQOS")..."
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState    = .connected
        peripheral.delegate = self
        peripheral.discoverServices([kIQOSCoreServiceUUID])
        statusMessage = "Συνδεδεμένο! Ανακάλυψη υπηρεσιών..."
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        stopPolling()
        connectionState   = .disconnected
        iqosPeripheral    = nil
        controlChar       = nil
        notifyChar        = nil
        statusMessage     = "Αποσυνδέθηκε — αναζήτηση..."
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        stopPolling()
        iqosPeripheral = nil
        scheduleReconnect()
    }

    // State restoration (background BLE)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral  = peripherals.first {
            iqosPeripheral      = peripheral
            peripheral.delegate = self
        }
    }
}

// ── CBPeripheralDelegate ──────────────────────────────────────────────────────
extension IQOSBLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            // Discover characteristics on all services
            peripheral.discoverCharacteristics([kSCPControlCharUUID, kILUMAControlCharUUID, kSCPNotifyCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            if char.uuid == kILUMAControlCharUUID || char.uuid == kSCPControlCharUUID {
                if controlChar == nil || char.uuid == kILUMAControlCharUUID {
                    controlChar = char
                }
            }
            if char.uuid == kSCPNotifyCharUUID  {
                notifyChar = char
                peripheral.setNotifyValue(true, for: char)
            }
        }
        if controlChar != nil {
            statusMessage = "Συνδεδεμένο ✓"
            Task { await evaluateLimit() }
            startPolling()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == kSCPNotifyCharUUID,
              let data = characteristic.value else { return }

        // Ολοκλήρωση pending async request
        if let continuation = pendingResponse {
            pendingResponse = nil
            continuation.resume(returning: data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Χρησιμοποιούμε withoutResponse, οπότε δεν χρειάζεται αυτό
    }
}

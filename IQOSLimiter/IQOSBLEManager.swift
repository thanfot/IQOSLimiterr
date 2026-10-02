import CoreBluetooth
import Combine
import UserNotifications

// ── IQOS BLE Protocol Constants ───────────────────────────────────────────────
// Βασισμένο στο https://github.com/hauntedfail/iqos (GPL-3.0)

private let kIQOSCoreServiceUUID     = CBUUID(string: "daebb240-b041-11e4-9e45-0002a5d5c51b")
private let kSCPControlCharUUID      = CBUUID(string: "daebb241-b041-11e4-9e45-0002a5d5c51b")
private let kSCPNotifyCharUUID       = CBUUID(string: "daebb242-b041-11e4-9e45-0002a5d5c51b")

// Telemetry command (puff count)
private let kTelemetryCmd   = Data([0x00, 0xC9, 0x10, 0x02, 0x01, 0x01, 0x75, 0xD6])
// Lock sequence
private let kLockCmd1       = Data([0x00, 0xC9, 0x44, 0x04, 0x02, 0xFF, 0x00, 0x00, 0x5A])
private let kLockCmd2       = Data([0x00, 0xC9, 0x00, 0x04, 0x1C])
// Unlock sequence
private let kUnlockCmd1     = Data([0x00, 0xC9, 0x44, 0x04, 0x00, 0x00, 0x00, 0x00, 0x5D])
private let kUnlockCmd2     = Data([0x00, 0xC9, 0x00, 0x04, 0x1C])

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
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
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
        if controlChar == nil && notifyChar == nil {
            statusMessage = "⏳ Αναμονή ετοιμασίας καναλιών Bluetooth..."
            return nil
        } else if controlChar == nil {
            statusMessage = "⏳ Αναμονή καναλιού εντολών (SCP Control)..."
            return nil
        }

        do {
            let response = try await sendCommand(kTelemetryCmd)
            return parsePuffCount(from: response)
        } catch {
            statusMessage = "⚠️ Σφάλμα ανάγνωσης: \(error.localizedDescription)"
            return nil
        }
    }

    private func parsePuffCount(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4,
              bytes[2] == kTelemetryHeader[0],
              bytes[3] == kTelemetryHeader[1] else { return nil }

        let payload = Array(bytes.dropFirst(4))
        let blockSize = 8
        var i = 0
        while i + blockSize <= payload.count {
            let block = Array(payload[i ..< i + blockSize])
            let tag   = block[7]
            if tag == kTagPuffCount {
                let value = Int(block[4]) | (Int(block[5]) << 8)
                return value
            }
            i += blockSize
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
        peripheral.discoverServices(nil)
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
        if let err = error {
            statusMessage = "❌ Σφάλμα υπηρεσιών: \(err.localizedDescription)"
            return
        }
        guard let services = peripheral.services else {
            statusMessage = "⚠️ Δεν βρέθηκαν υπηρεσίες BLE"
            return
        }
        statusMessage = "📂 Βρέθηκαν \(services.count) υπηρεσίες. Αναζήτηση καναλιών..."
        for service in services {
            let u = service.uuid.uuidString.lowercased()
            if u.contains("daebb240") || service.uuid == kIQOSCoreServiceUUID {
                statusMessage = "🎯 Εντοπίστηκε IQOS Core Service!"
            }
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let err = error {
            statusMessage = "❌ Σφάλμα καναλιών: \(err.localizedDescription)"
            return
        }
        guard let chars = service.characteristics else { return }

        let sUUID = service.uuid.uuidString.lowercased()
        let isIQOSCore = sUUID.contains("daebb240") || service.uuid == kIQOSCoreServiceUUID

        for char in chars {
            let u = char.uuid.uuidString.lowercased()
            if u.contains("daebb241") || char.uuid == kSCPControlCharUUID || (isIQOSCore && (char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse))) {
                controlChar = char
            }
            if u.contains("daebb242") || char.uuid == kSCPNotifyCharUUID || (isIQOSCore && char.properties.contains(.notify)) {
                notifyChar = char
                peripheral.setNotifyValue(true, for: char)
            }
        }

        if controlChar != nil {
            statusMessage = "Συνδεδεμένο ✓"
            Task { await evaluateLimit() }
            startPolling()
        } else if isIQOSCore {
            statusMessage = "⚠️ Εντοπίστηκε IQOS Service, ετοιμασία καναλιών..."
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

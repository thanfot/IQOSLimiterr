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
private let kPauseModeOnCmd   = buildIQOSCommand(opcode: 0xD2, reg: [0x45, 0x22], payload: [0x01, 0x00, 0x00])
private let kPauseModeOffCmd  = buildIQOSCommand(opcode: 0xD2, reg: [0x45, 0x22], payload: [0x00, 0x00, 0x00])
private let kIlumaPowerOffCmd = buildIQOSCommand(opcode: 0xD2, reg: [0x05, 0x22], payload: [0x00, 0x00, 0x00])

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
    @Published var rawPuffsToday: Int = 0
    @Published var dailyLimit: Int    = UserDefaults.standard.object(forKey: "iqos.limit") == nil
                                            ? 5
                                            : UserDefaults.standard.integer(forKey: "iqos.limit")
    @Published var isLocked: Bool     = DailyState.locked
    @Published var statusMessage: String = "Άνοιξε την εφαρμογή για να ξεκινήσει"
    @Published var lifetimePuffs: Int = 0
    @Published var totalLifetimeSticks: Int = UserDefaults.standard.integer(forKey: "iqos.totalLifetimeSticks")
    @Published var rawTelemetryBytes: [UInt8] = []
    @Published var lastGATTPackets: [[String: String]] = []

    private func recordGATTResponse(characteristicUUID: String, data: Data) {
        let bytes = [UInt8](data)
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        Task { @MainActor in
            self.rawTelemetryBytes = bytes
            self.lastGATTPackets.append([
                "char_uuid": characteristicUUID,
                "length": "\(bytes.count)",
                "raw_hex": hex,
                "time": Date().description
            ])
            if self.lastGATTPackets.count > 20 {
                self.lastGATTPackets.removeFirst()
            }
        }
    }

    func exportRawDeviceData() -> String {
        let info: [String: Any] = [
            "raw_bluetooth_packets_from_iqos": lastGATTPackets,
            "device_name": iqosPeripheral?.name ?? "IQOS ILUMA i PRIME",
            "device_uuid": iqosPeripheral?.identifier.uuidString ?? "N/A",
            "connection_state": connectionState.label,
            "puffs_today_sticks": puffsToday,
            "raw_puffs_today": rawPuffsToday,
            "total_lifetime_sticks": totalLifetimeSticks,
            "lifetime_puffs_raw": lifetimePuffs,
            "daily_limit": dailyLimit,
            "is_locked": isLocked,
            "daily_baseline": DailyState.baseline ?? 0,
            "last_status_message": statusMessage,
            "last_telemetry_hex": rawTelemetryBytes.map { String(format: "%02X", $0) }.joined(separator: " "),
            "device_settings": [
                "pause_mode": pauseModeEnabled,
                "flex_puff": flexPuffEnabled,
                "autostart": autostartEnabled,
                "vibration": vibrationEnabled
            ],
            "timestamp": Date().description
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: info, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }

    // ── IQOS Settings Published State ─────────────────────────────────────────
    @Published var pauseModeEnabled: Bool = false
    @Published var flexPuffEnabled: Bool  = true
    @Published var autostartEnabled: Bool = true
    @Published var vibrationEnabled: Bool = true

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
        // Σάρωση όλων των συσκευών χωρίς περιορισμό Service UUID
        centralManager.scanForPeripherals(withServices: nil,
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func setDailyLimit(_ limit: Int) {
        dailyLimit = limit
        UserDefaults.standard.set(limit, forKey: "iqos.limit")
        Task { await evaluateLimit() }
    }

    func setTotalLifetimeSticks(_ count: Int) {
        totalLifetimeSticks = count
        UserDefaults.standard.set(count, forKey: "iqos.totalLifetimeSticks")
    }

    func manualLock() {
        Task { await sendLock() }
    }

    func manualUnlock() {
        Task { await sendUnlock() }
    }

    func togglePauseMode(_ enabled: Bool) {
        pauseModeEnabled = enabled
        let cmd = enabled ? kPauseModeOnCmd : kPauseModeOffCmd
        sendNoResponse(cmd)
    }

    func toggleFlexPuff(_ enabled: Bool) {
        flexPuffEnabled = enabled
        let cmd = buildIQOSCommand(opcode: 0xD2, reg: [0x47, 0x24], payload: [enabled ? 0x01 : 0x00, 0x00])
        sendNoResponse(cmd)
    }

    func toggleAutostart(_ enabled: Bool) {
        autostartEnabled = enabled
        let cmd = buildIQOSCommand(opcode: 0xD2, reg: [0x40, 0x24], payload: [enabled ? 0x01 : 0x00, 0x00])
        sendNoResponse(cmd)
    }

    func toggleVibration(_ enabled: Bool) {
        vibrationEnabled = enabled
        let cmd = buildIQOSCommand(opcode: 0xD2, reg: [0x12, 0x22], payload: [enabled ? 0x01 : 0x00, 0x00])
        sendNoResponse(cmd)
    }

    func addStick() {
        puffsToday += 1
        totalLifetimeSticks += 1
        DailyState.puffsToday = puffsToday
        UserDefaults.standard.set(totalLifetimeSticks, forKey: "iqos.totalLifetimeSticks")
        Task { await evaluateLimit() }
    }

    func removeStick() {
        puffsToday = max(0, puffsToday - 1)
        totalLifetimeSticks = max(0, totalLifetimeSticks - 1)
        DailyState.puffsToday = puffsToday
        UserDefaults.standard.set(totalLifetimeSticks, forKey: "iqos.totalLifetimeSticks")
        Task { await evaluateLimit() }
    }

    func resetTodayBaseline() {
        Task { @MainActor in
            let count = await readPuffCount() ?? (self.lifetimePuffs > 0 ? self.lifetimePuffs : 1)
            DailyState.baseline = count
            self.lifetimePuffs = count
            self.puffsToday = 0
            self.rawPuffsToday = 0
            DailyState.puffsToday = 0
            self.statusMessage = "📌 Μηδενισμός ημέρας επιτυχής (0 sticks σήμερα)"
            if self.isLocked {
                await self.sendUnlock()
            }
        }
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


    private func sendCommand(_ data: Data, timeoutSeconds: Double = 2.0) async throws -> Data {
        guard let peripheral = iqosPeripheral,
              let char = controlChar,
              peripheral.state == .connected else {
            throw NSError(domain: "IQOSLimiter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Λείπει το κανάλι αποστολής εντολών"])
        }
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

        if let old = pendingResponse {
            pendingResponse = nil
            old.resume(throwing: NSError(domain: "IQOSLimiter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cancelled by new command"]))
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            self.pendingResponse = continuation
            peripheral.writeValue(data, for: char, type: writeType)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self = self else { return }
                if let pending = self.pendingResponse {
                    self.pendingResponse = nil
                    pending.resume(throwing: NSError(domain: "IQOSLimiter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timeout αναμονής Bluetooth"]))
                }
            }
        }
    }

    private func sendNoResponse(_ data: Data) {
        guard let peripheral = iqosPeripheral, let char = controlChar else { return }
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: char, type: writeType)
    }

    // ── Telemetry ─────────────────────────────────────────────────────────────

    @MainActor
    private func readPuffCount() async -> Int? {
        guard controlChar != nil else { return nil }

        do {
            let response = try await sendCommand(kTelemetryCmd)
            recordGATTResponse(characteristicUUID: controlChar?.uuid.uuidString ?? "ILUMA", data: response)
            if let count = parsePuffCount(from: response) { return count }
        } catch {}

        // Fallback: ILUMA 0x1007 Log Query
        do {
            let ilumaCmd = buildIQOSCommand(opcode: 0xC9, reg: [0x10, 0x07], payload: [0x01, 0x02, 0x00, 0x01])
            let response = try await sendCommand(ilumaCmd)
            recordGATTResponse(characteristicUUID: controlChar?.uuid.uuidString ?? "ILUMA", data: response)
            if let count = parsePuffCount(from: response) { return count }
        } catch {}

        return nil
    }

    private func parsePuffCount(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { return nil }

        // 1. TLV Block Parsing
        let payload = Array(bytes.dropFirst(4))
        let blockSize = 8
        var i = 0
        while i + blockSize <= payload.count {
            let block = Array(payload[i ..< i + blockSize])
            let value = Int(block[4]) | (Int(block[5]) << 8)
            // Αποκλείουμε μόνο τις επικεφαλίδες και τα echo bytes (256, 257, 8848, 1808)
            if value > 0 && value != 256 && value != 257 && value != 8848 && value != 1808 {
                return value
            }
            i += blockSize
        }

        // 2. Fallback: Αναζήτηση ακέραιου
        for idx in stride(from: 5, to: bytes.count - 1, by: 1) {
            let val = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            if val >= 10 && val < 65000 && val != 256 && val != 257 && val != 8848 && val != 1808 {
                return val
            }
        }

        return nil
    }

    // ── Lock / Unlock ─────────────────────────────────────────────────────────

    @MainActor
    private func sendLock() async {
        sendNoResponse(kLockCmd1)
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        sendNoResponse(kLockCmd2)
        try? await Task.sleep(nanoseconds: 200_000_000)
        sendNoResponse(kIlumaPowerOffCmd)
        try? await Task.sleep(nanoseconds: 100_000_000)
        sendNoResponse(kPauseModeOnCmd)
        isLocked         = true
        DailyState.locked = true
        statusMessage     = "🔒 Κλειδωμένο — Επίτευξες το ημερήσιο όριο!"
        sendNotification(title: "IQOS Κλειδωμένο 🔒",
                         body: "Έφτασες τα \(dailyLimit) sticks για σήμερα. Καλή συνέχεια!")
    }

    @MainActor
    private func sendUnlock() async {
        sendNoResponse(kUnlockCmd1)
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        sendNoResponse(kUnlockCmd2)
        try? await Task.sleep(nanoseconds: 200_000_000)
        sendNoResponse(kPauseModeOffCmd)
        isLocked         = false
        DailyState.locked = false
        statusMessage     = "🔓 Ξεκλειδωμένο"
    }

    // ── Limit evaluation ──────────────────────────────────────────────────────

    @MainActor
    func evaluateLimit() async {
        DailyState.resetIfNewDay()

        guard let lifetimeCount = await readPuffCount() else { return }

        lifetimePuffs = lifetimeCount
        if totalLifetimeSticks == 0 {
            setTotalLifetimeSticks(lifetimeCount)
        }

        // Ορισμός baseline αν είναι πρώτη φορά σήμερα ή αν το baseline είναι 0/άκυρο
        let currentBaseline = DailyState.baseline ?? 0
        if currentBaseline <= 0 || currentBaseline > lifetimeCount {
            DailyState.baseline = lifetimeCount
            statusMessage = "📌 Σημεία εκκίνησης: \(lifetimeCount) puffs"
        }

        let diff = max(0, lifetimeCount - (DailyState.baseline ?? lifetimeCount))
        rawPuffsToday = diff

        // Κάθε αύξηση κατά 14-18 μονάδες από τη συσκευή αντιστοιχεί σε ακριβώς +1 Stick (π.χ. 1/20)
        let sticksToday: Int
        if diff <= 0 {
            sticksToday = 0
        } else {
            sticksToday = (diff - 1) / 14 + 1
        }

        puffsToday = sticksToday
        DailyState.puffsToday = sticksToday

        let remaining = max(0, dailyLimit - sticksToday)

        if sticksToday >= dailyLimit {
            statusMessage = "🚫 Όριο! \(sticksToday)/\(dailyLimit) sticks"
            if !isLocked { await sendLock() }
        } else {
            statusMessage = "✅ \(sticksToday)/\(dailyLimit) sticks — Απομένουν \(remaining)"
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
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let upperName = name.uppercased()

        // Αγνοούμε συσκευές που ΔΕΝ είναι IQOS (π.χ. Τηλεόραση, Ηχεία)
        guard upperName.contains("IQOS") || upperName.contains("ILUMA") || upperName.contains("DUO") else { return }

        guard iqosPeripheral == nil else { return }
        central.stopScan()
        iqosPeripheral  = peripheral
        connectionState = .connecting
        statusMessage   = "Σύνδεση με \(name)..."
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState    = .connected
        peripheral.delegate = self
        // Discover ALL services on IQOS ILUMA
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
        guard let services = peripheral.services else { return }
        for service in services {
            // Discover ALL characteristics under every service
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            let props = char.properties
            // Έλεγχος για θύρα εγγραφής (Write / WriteWithoutResponse)
            if char.uuid == kILUMAControlCharUUID || char.uuid == kSCPControlCharUUID || props.contains(.write) || props.contains(.writeWithoutResponse) {
                if controlChar == nil || char.uuid == kILUMAControlCharUUID {
                    controlChar = char
                }
            }
            // Έλεγχος για θύρα ειδοποιήσεων (Notify / Indicate)
            if char.uuid == kSCPNotifyCharUUID || props.contains(.notify) || props.contains(.indicate) {
                if notifyChar == nil {
                    notifyChar = char
                    peripheral.setNotifyValue(true, for: char)
                }
            }
        }
        if controlChar != nil {
            statusMessage = "Συνδεδεμένο ✓ (Έτοιμο για εντολές)"
            Task { await evaluateLimit() }
            startPolling()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }

        let bytes = [UInt8](data)
        recordGATTResponse(characteristicUUID: characteristic.uuid.uuidString, data: data)

        // 1. Ολοκλήρωση pending async request αν υπάρχει
        if let continuation = pendingResponse {
            // Φιλτράρισμα ECHO πακέτων (Short packets <= 8 bytes)
            if bytes.count <= 8 && bytes.count >= 6 && bytes[0] == 0x00 && bytes[1] == 0xC9 && bytes[4] == 0x01 && bytes[5] == 0x01 {
                return
            }
            pendingResponse = nil
            continuation.resume(returning: data)
            return
        }

        // 2. Ενημέρωση telemetry για ασφαλή υπολογισμό ορίου
        Task { @MainActor in
            await self.evaluateLimit()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Χρησιμοποιούμε withoutResponse, οπότε δεν χρειάζεται αυτό
    }
}

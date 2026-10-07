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

// Ο μετρητής tag 0x8E της συσκευής μετράει ΤΕΡΕΑ (sticks), όχι μεμονωμένα puffs.
// Επιβεβαιωμένο 2026-10-05: δύο καπνίσματα → μετρητής +2.
private let kCounterIsInSticks = true

// ── Daily State (UserDefaults) ────────────────────────────────────────────────
struct DailyState {
    static let keyDate          = "iqos.date"
    static let keyBaseline      = "iqos.baseline"
    static let keyPuffsToday    = "iqos.puffsToday"
    static let keyLocked        = "iqos.locked"
    static let keyLimitToday    = "iqos.limit"
    static let keyLimitNext     = "iqos.limit.next"

    static var today: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    static func resetIfNewDay() {
        let ud = UserDefaults.standard
        if ud.string(forKey: keyDate) != today {
            // Νέα μέρα: το προγραμματισμένο όριο γίνεται το όριο της ημέρας.
            if ud.object(forKey: keyLimitNext) != nil {
                ud.set(ud.integer(forKey: keyLimitNext), forKey: keyLimitToday)
            }
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

// ── Telemetry Field ──────────────────────────────────────────────────────────
/// Ένα αποκωδικοποιημένο 8-byte TLV block της απόκρισης IQOS
struct TelemetryField: Identifiable {
    let tag: UInt8
    let value: Int
    var id: UInt8 { tag }

    var tagHex: String { String(format: "0x%02X", tag) }
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
    @Published var dailyLimit: Int    = UserDefaults.standard.object(forKey: DailyState.keyLimitToday) == nil
                                            ? 5
                                            : UserDefaults.standard.integer(forKey: DailyState.keyLimitToday)
    /// Όριο που θα ισχύσει από την επόμενη μέρα (ελεύθερα αλλάζει χωρίς PIN)
    @Published var nextDayLimit: Int  = UserDefaults.standard.object(forKey: DailyState.keyLimitNext) == nil
                                            ? (UserDefaults.standard.object(forKey: DailyState.keyLimitToday) == nil
                                                ? 5
                                                : UserDefaults.standard.integer(forKey: DailyState.keyLimitToday))
                                            : UserDefaults.standard.integer(forKey: DailyState.keyLimitNext)
    // ── Admin (PIN) ───────────────────────────────────────────────────────────
    static let pinKey       = "iqos.admin.pin"
    static let pinFailsKey  = "iqos.admin.fails"
    static let pinMaxFails  = 5
    /// Επίτρεπει αλλαγή σημερινού ορίου / lock / unlock / reset
    @Published var isAdmin: Bool = false
    /// Εμφάνιση του PIN pad (το πετάει ο View)
    @Published var showPinPrompt: Bool = false
    @Published var pinFailures: Int = UserDefaults.standard.integer(forKey: IQOSBLEManager.pinFailsKey)
    @Published var isLocked: Bool     = DailyState.locked
    @Published var statusMessage: String = "Άνοιξε την εφαρμογή για να ξεκινήσει"
    @Published var lifetimePuffs: Int = 0
    @Published var totalLifetimeSticks: Int = UserDefaults.standard.integer(forKey: "iqos.totalLifetimeSticks")
    @Published var currentStickProgress: Double = 0
    @Published var rawTelemetryBytes: [UInt8] = []
    @Published var lastGATTPackets: [[String: String]] = []
    /// Όλα τα αποκωδικοποιημένα πεδία telemetry (για debug / εντοπισμό άλλων counters)
    @Published var telemetryFields: [TelemetryField] = []
    /// Το τελευταίο αποδεκτό lifetime puff count (tag 0x8E)
    private var lastPuffCount: Int = 0

    private func recordGATTResponse(characteristicUUID: String, data: Data) {
        let bytes = [UInt8](data)
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let entry: [String: String] = [
            "char_uuid": characteristicUUID,
            "length": "\(bytes.count)",
            "raw_hex": hex,
            "time": Date().description
        ]
        Task { @MainActor in
            self.rawTelemetryBytes = bytes
            self.lastGATTPackets.append(entry)
            if self.lastGATTPackets.count > 20 {
                self.lastGATTPackets.removeFirst(self.lastGATTPackets.count - 20)
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
            "counter_unit": "sticks",
            "parsed_lifetime_puffs": lastPuffCount,
            "decoded_telemetry_fields": telemetryFields.map { ["tag": $0.tagHex, "value": $0.value] },
            "daily_limit": dailyLimit,
            "is_locked": isLocked,
            "daily_baseline": DailyState.baseline ?? 0,
            "last_evaluation": lastEvaluation == .distantPast ? "never" : lastEvaluation.description,
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
    private var isEvaluating = false
    private var lastEvaluation: Date = .distantPast
    private var pendingEvaluation: DispatchWorkItem?

    override init() {
        super.init()
        DailyState.resetIfNewDay()
        syncLimitFromStorage()
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
        #if os(iOS)
        // Το iOS CoreBluetooth κρύβει το όνομα της συσκευής (ιδιωτικότητα),
        // οπότε το peripheral.name είναι κενό και δεν φιλτράρει.
        // Το IQOS διαφημίζει το core service UUID — φιλτράρουμε με βάση αυτό.
        centralManager.scanForPeripherals(withServices: [kIQOSCoreServiceUUID],
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        #else
        // Σάρωση όλων των συσκευών χωρίς περιορισμό Service UUID
        centralManager.scanForPeripherals(withServices: nil,
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        #endif
    }

    /// Φέρνει τα όρια από το UserDefaults στα published vars — κλήση μετά κάθε
    /// DailyState.resetIfNewDay(), αλλιώς το rollover δεν φαίνεται μέχρι restart.
    private func syncLimitFromStorage() {
        let ud = UserDefaults.standard
        if ud.object(forKey: DailyState.keyLimitToday) != nil {
            dailyLimit = ud.integer(forKey: DailyState.keyLimitToday)
        }
        if ud.object(forKey: DailyState.keyLimitNext) != nil {
            nextDayLimit = ud.integer(forKey: DailyState.keyLimitNext)
        } else {
            nextDayLimit = dailyLimit
        }
    }

    /// Κανονική αλλαγή: ισχύει από την επόμενη μέρα. Δεν χρειάζεται PIN.
    func setNextDayLimit(_ limit: Int) {
        nextDayLimit = limit
        UserDefaults.standard.set(limit, forKey: DailyState.keyLimitNext)
        if isAdmin { setTodayLimit(limit) }
    }

    /// Admin αλλαγή: ισχύει άμεσα για σήμερα. Απαιτεί isAdmin.
    func setTodayLimit(_ limit: Int) {
        guard isAdmin else { showPinPrompt = true; return }
        dailyLimit = limit
        UserDefaults.standard.set(limit, forKey: DailyState.keyLimitToday)
        Task { await evaluateLimit() }
    }

    // ── PIN ────────────────────────────────────────────────────────────────────

    /// Το προεπιλεγμένο PIN όταν δεν έχει οριστεί ακόμη.
    static let defaultPin = "0000"

    var storedPin: String { UserDefaults.standard.string(forKey: Self.pinKey) ?? Self.defaultPin }

    var hasCustomPin: Bool { UserDefaults.standard.string(forKey: Self.pinKey) != nil }

    /// Ελέγχει κωδικό. Σωστό → admin. Λάθος → μετρητής, στο pinMaxFails επιτρέπεται καθαρισμός.
    @discardableResult
    func verifyPin(_ pin: String) -> Bool {
        if pin == storedPin {
            isAdmin = true
            pinFailures = 0
            UserDefaults.standard.set(0, forKey: Self.pinFailsKey)
            return true
        }
        pinFailures += 1
        UserDefaults.standard.set(pinFailures, forKey: Self.pinFailsKey)
        return false
    }

    var canResetPin: Bool { pinFailures >= Self.pinMaxFails }

    /// Κλείνει το admin mode (π.χ. όταν κλείσει το sheet).
    func endAdminSession() { isAdmin = false }

    func setNewPin(_ pin: String) {
        UserDefaults.standard.set(pin, forKey: Self.pinKey)
        pinFailures = 0
        UserDefaults.standard.set(0, forKey: Self.pinFailsKey)
        isAdmin = true
    }

    /// Recovery όταν έχασες τον κωδικό: καθαρισμός ρυθμίσεων + ξεκλείδωμα
    /// συσκευής, ώστε να μην μείνεις ποτέ μπλοκαρισμένος από το IQOS.
    func resetAdminAccess() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: Self.pinKey)
        ud.removeObject(forKey: Self.pinFailsKey)
        pinFailures = 0
        isAdmin = true

        // Καθαρισμός ημερήσιας κατάστασης
        ud.removeObject(forKey: DailyState.keyBaseline)
        ud.removeObject(forKey: DailyState.keyLimitNext)
        ud.set(0, forKey: DailyState.keyPuffsToday)
        puffsToday = 0
        rawPuffsToday = 0
        currentStickProgress = 0

        // Ξεκλείδωμα συσκευής — δεν μπορείς να μείνεις μπλοκαρισμένος
        if isLocked {
            Task { await sendUnlock() }
        }
        Task { await evaluateLimit() }
    }

    func setTotalLifetimeSticks(_ count: Int) {
        guard isAdmin else { showPinPrompt = true; return }
        totalLifetimeSticks = count
        UserDefaults.standard.set(count, forKey: "iqos.totalLifetimeSticks")
    }

    func manualLock() {
        guard isAdmin else { showPinPrompt = true; return }
        Task { await sendLock() }
    }

    func manualUnlock() {
        guard isAdmin else { showPinPrompt = true; return }
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

    func resetTodayBaseline() {
        guard isAdmin else { showPinPrompt = true; return }
        Task { @MainActor in
            guard !isEvaluating else { return }
            isEvaluating = true
            defer { isEvaluating = false }

            let current = await readPuffCount() ?? lifetimePuffs
            guard current > 0 else {
                statusMessage = "⚠️ Μηδενισμός απέτυχε — δεν διαβάστηκε το puff count"
                return
            }

            DailyState.resetIfNewDay()
            syncLimitFromStorage()
            DailyState.baseline = current
            DailyState.puffsToday = 0
            DailyState.locked  = false

            lifetimePuffs        = current
            puffsToday           = 0
            rawPuffsToday        = 0
            currentStickProgress = 0

            statusMessage = "📌 Μηδενισμός ημέρας: baseline = \(current) puffs (0 sticks)"

            if isLocked { await sendUnlock() }
            await evaluateLimit()
        }
    }

    func manualRefresh() {
        Task { await evaluateLimit() }
    }

    // ── Polling Timer ─────────────────────────────────────────────────────────

    private func startPolling() {
        stopPolling()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { await self?.scheduleEvaluation(after: 0.0) }
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    /// Εκκίνηση αξιολόγησης με καθυστέρηση — ακυρώνει οποιαδήποτε προηγούμενη αναμονή
    @MainActor
    private func scheduleEvaluation(after delay: TimeInterval) {
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.evaluateLimit() }
        }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
                guard let self else { return }
                Task { @MainActor in
                    if let pending = self.pendingResponse {
                        self.pendingResponse = nil
                        pending.resume(throwing: NSError(domain: "IQOSLimiter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timeout αναμονής Bluetooth"]))
                    }
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

    /// Header 6 bytes: [00 08 90 22 01 01]
    /// Μετά ακολουθούν 8-byte TLV blocks: [idx:1][00 00 00][u16 LE:2][00][tag:1]
    /// Στο τέλος 2 trailing bytes (tag + CRC).
    private static let telemetryHeaderLength = 6
    private static let telemetryTrailerLength = 2

    /// Επιστρέφει τα αποκωδικοποιημένα πεδία telemetry (tag → τιμή)
    private func decodeTelemetry(_ data: Data) -> [TelemetryField] {
        let bytes = [UInt8](data)
        let end = bytes.count - Self.telemetryTrailerLength
        guard bytes.count >= Self.telemetryHeaderLength + 8 + Self.telemetryTrailerLength,
              end > Self.telemetryHeaderLength else { return [] }

        var fields: [TelemetryField] = []
        var offset = Self.telemetryHeaderLength
        while offset + 8 <= end {
            let b = Array(bytes[offset ..< offset + 8])
            // Επιβεβαίωση ότι είναι αξιόπιστο block (τα 3 bytes είναι padding)
            if b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x00 {
                let value = Int(b[4]) | (Int(b[5]) << 8)
                fields.append(TelemetryField(tag: b[7], value: value))
            }
            offset += 8
        }
        return fields
    }

    @MainActor
    private func readPuffCount() async -> Int? {
        guard controlChar != nil else { return nil }

        var decoded: [TelemetryField] = []

        do {
            let response = try await sendCommand(kTelemetryCmd)
            recordGATTResponse(characteristicUUID: controlChar?.uuid.uuidString ?? "ILUMA", data: response)
            decoded += decodeTelemetry(response)
        } catch {}

        // Fallback: ILUMA 0x1007 Log Query
        do {
            let ilumaCmd = buildIQOSCommand(opcode: 0xC9, reg: [0x10, 0x07], payload: [0x01, 0x02, 0x00, 0x01])
            let response = try await sendCommand(ilumaCmd)
            recordGATTResponse(characteristicUUID: controlChar?.uuid.uuidString ?? "ILUMA", data: response)
            decoded += decodeTelemetry(response)
        } catch {}

        telemetryFields = decoded

        // Μόνο το tag 0x8E θεωρείται puff count — δεν μαντεύουμε άλλο πεδίο
        if let field = decoded.last(where: { $0.tag == kTagPuffCount }) {
            lastPuffCount = field.value
            return field.value
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
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false; lastEvaluation = Date() }

        DailyState.resetIfNewDay()
        syncLimitFromStorage()

        guard let lifetimeCount = await readPuffCount() else { return }

        lifetimePuffs = lifetimeCount
        if totalLifetimeSticks == 0 {
            setTotalLifetimeSticks(lifetimeCount)
        }

        // Ορισμός baseline αν είναι πρώτη φορά σήμερα ή αν το baseline είναι 0/άκυρο
        var currentBaseline = DailyState.baseline ?? 0

        // Repair: το παλιό bug έγραφε baseline = 1 → τεράστια νούμερα. Ξαναβάζουμε baseline.
        let maxPlausibleDiff = 60
        if currentBaseline > 0 && lifetimeCount - currentBaseline > maxPlausibleDiff {
            currentBaseline = lifetimeCount
            DailyState.baseline = lifetimeCount
            statusMessage = "⚠️ Baseline διορθώθηκε στα \(lifetimeCount)"
        }

        if currentBaseline <= 0 || currentBaseline > lifetimeCount {
            currentBaseline = lifetimeCount
            DailyState.baseline = lifetimeCount
            statusMessage = "📌 Σημεία εκκίνησης: \(lifetimeCount)"
        }

        // Ο μετρητής της συσκευής είναι σε τερέα → το diff είναι ήδη sticks
        let diff = max(0, lifetimeCount - currentBaseline)
        let sticksToday = kCounterIsInSticks ? diff : Int((Double(diff) / 19.0).rounded())
        rawPuffsToday = diff
        currentStickProgress = 0

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
            #if os(iOS)
            if central.authorization == .denied || central.authorization == .restricted {
                statusMessage = "Άνοιξε: Ρυθμίσεις → Απόρρητο → Bluetooth"
            } else {
                statusMessage = "Bluetooth απενεργοποιημένο"
            }
            #else
            statusMessage = "Bluetooth απενεργοποιημένο"
            #endif
            connectionState = .idle
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        var displayName: String

        #if os(iOS)
        // Στο iOS το όνομα είναι κενό. Δεχόμαστε μόνο συσκευές που
        // διαφημίζουν το IQOS core service UUID (επιβεβαιωμένο με capture).
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard advertised.contains(kIQOSCoreServiceUUID) else { return }
        displayName = peripheral.name ?? "IQOS"
        #else
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let upperName = name.uppercased()

        // Αγνοούμε συσκευές που ΔΕΝ είναι IQOS (π.χ. Τηλεόραση, Ηχεία)
        guard upperName.contains("IQOS") || upperName.contains("ILUMA") || upperName.contains("DUO") else { return }
        displayName = name
        #endif

        guard iqosPeripheral == nil else { return }
        central.stopScan()
        iqosPeripheral  = peripheral
        connectionState = .connecting
        statusMessage   = "Σύνδεση με \(displayName)..."
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

        // 1. Ολοκλήρωση pending async request αν υπάρχει
        if let continuation = pendingResponse {
            recordGATTResponse(characteristicUUID: characteristic.uuid.uuidString, data: data)

            // Φιλτράρισμα ECHO πακέτων (Short packets <= 8 bytes)
            if bytes.count <= 8 && bytes.count >= 6 && bytes[0] == 0x00 && bytes[1] == 0xC9 && bytes[4] == 0x01 && bytes[5] == 0x01 {
                return
            }
            pendingResponse = nil
            continuation.resume(returning: data)
            return
        }

        // 2. Spontaneous notifications: καταγραφή + debounced αξιολόγηση
        // (debounce ώστε να μην γίνει loop: εντολή → notification → εντολή)
        recordGATTResponse(characteristicUUID: characteristic.uuid.uuidString, data: data)
        Task { @MainActor in
            self.scheduleEvaluation(after: 3.0)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // Χρησιμοποιούμε withoutResponse, οπότε δεν χρειάζεται αυτό
    }
}

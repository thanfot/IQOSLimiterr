import CoreBluetooth
import CryptoKit
import Security
import Combine
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

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

/// Αν ο μετρητής ήταν σε puffs, τόσα puffs ≈ 1 stick.
private let kPuffsPerStick = 19.0
/// Μεγαλύτερη διαφορά από το baseline θεωρείται corrupt baseline (repair).
private let kMaxPlausibleDailyDiff = 60
/// Η «μέρα» αλλάζει στις 04:00 (όχι τα μεσάνυχτα), ώστε τα βραδινά να μετράνε στην ίδια μέρα.
private let kDayStartHour = 4

// ── Daily State (UserDefaults) ────────────────────────────────────────────────
struct DailyState {
    static let keyDate          = "iqos.date"
    static let keyBaseline      = "iqos.baseline"
    static let keyLastLifetime  = "iqos.lastLifetime"
    static let keyPrevDate      = "iqos.prevDate"
    static let keyPuffsToday    = "iqos.puffsToday"
    static let keyLocked        = "iqos.locked"
    static let keyLimitToday    = "iqos.limit"
    static let keyLimitNext     = "iqos.limit.next"
    static let keyNotifiedLimit   = "iqos.notified.limit"
    static let keyNotifiedOneLeft = "iqos.notified.oneLeft"
    static let keyNotifiedHalf    = "iqos.notified.half"

    static var today: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let shifted = Calendar.current.date(byAdding: .hour, value: -kDayStartHour, to: Date()) ?? Date()
        return fmt.string(from: shifted)
    }

    static func resetIfNewDay() {
        let ud = UserDefaults.standard
        if ud.string(forKey: keyDate) != today {
            // Αρχειοθέτηση της προηγούμενης μέρας στο ιστορικό
            if let prevDate = ud.string(forKey: keyDate) {
                ud.set(prevDate, forKey: keyPrevDate)
                UsageHistory.record(date: prevDate,
                                    sticks: ud.integer(forKey: keyPuffsToday),
                                    limit: ud.object(forKey: keyLimitToday) == nil ? 5 : ud.integer(forKey: keyLimitToday))
            }
            // Νέα μέρα: το προγραμματισμένο όριο γίνεται το όριο της ημέρας.
            if ud.object(forKey: keyLimitNext) != nil {
                ud.set(ud.integer(forKey: keyLimitNext), forKey: keyLimitToday)
            }
            ud.set(today, forKey: keyDate)
            ud.removeObject(forKey: keyBaseline)
            ud.set(0, forKey: keyPuffsToday)
            ud.set(false, forKey: keyLocked)
            ud.set(false, forKey: keyNotifiedLimit)
            ud.set(false, forKey: keyNotifiedOneLeft)
            ud.set(false, forKey: keyNotifiedHalf)
        }
    }

    static var baseline: Int? {
        get {
            let v = UserDefaults.standard.integer(forKey: keyBaseline)
            return UserDefaults.standard.object(forKey: keyBaseline) == nil ? nil : v
        }
        set { UserDefaults.standard.set(newValue, forKey: keyBaseline) }
    }

    /// Το τελευταίο lifetime count που είδε το app. Στη νέα μέρα γίνεται baseline,
    /// ώστε sticks που έγιναν ενώ το app ήταν κλειστό να μετρηθούν και όχι να χαθούν.
    static var lastLifetime: Int? {
        get {
            UserDefaults.standard.object(forKey: keyLastLifetime) == nil
                ? nil : UserDefaults.standard.integer(forKey: keyLastLifetime)
        }
        set { UserDefaults.standard.set(newValue, forKey: keyLastLifetime) }
    }

    static var puffsToday: Int {
        get { UserDefaults.standard.integer(forKey: keyPuffsToday) }
        set { UserDefaults.standard.set(newValue, forKey: keyPuffsToday) }
    }

    static var locked: Bool {
        get { UserDefaults.standard.bool(forKey: keyLocked) }
        set { UserDefaults.standard.set(newValue, forKey: keyLocked) }
    }

    /// Έχει σταλεί ήδη η ειδοποίηση «έφτασες το όριο» για σήμερα;
    static var notifiedLimit: Bool {
        get { UserDefaults.standard.bool(forKey: keyNotifiedLimit) }
        set { UserDefaults.standard.set(newValue, forKey: keyNotifiedLimit) }
    }

    /// Έχει σταλεί ήδη η ειδοποίηση «πέρασες το μισό όριο» για σήμερα;
    static var notifiedHalf: Bool {
        get { UserDefaults.standard.bool(forKey: keyNotifiedHalf) }
        set { UserDefaults.standard.set(newValue, forKey: keyNotifiedHalf) }
    }

    /// Έχει σταλεί ήδη η ειδοποίηση «μένει 1» για σήμερα;
    static var notifiedOneLeft: Bool {
        get { UserDefaults.standard.bool(forKey: keyNotifiedOneLeft) }
        set { UserDefaults.standard.set(newValue, forKey: keyNotifiedOneLeft) }
    }
}

// ── Usage History ─────────────────────────────────────────────────────────────
struct DayRecord: Codable, Identifiable {
    let date: String   // yyyy-MM-dd
    let sticks: Int
    let limit: Int
    var id: String { date }
}

enum UsageHistory {
    private static let key = "iqos.history"
    private static let maxDays = 90

    static var all: [DayRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([DayRecord].self, from: data) else { return [] }
        return list
    }

    static func record(date: String, sticks: Int, limit: Int) {
        var list = all.filter { $0.date != date }
        list.append(DayRecord(date: date, sticks: sticks, limit: limit))
        list.sort { $0.date < $1.date }
        if list.count > maxDays { list = Array(list.suffix(maxDays)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Προσθέτει sticks σε μια ήδη αρχειοθετημένη μέρα (π.χ. όσα έγιναν όσο το app ήταν αποσυνδεδεμένο).
    static func add(date: String, sticks: Int) {
        let existing = all.first { $0.date == date }
        record(date: date,
               sticks: (existing?.sticks ?? 0) + sticks,
               limit: existing?.limit ?? 5)
    }

    /// Τελευταίες `days` μέρες (παλιότερη → νεότερη) συμπεριλαμβανομένης της σημερινής.
    static func recent(days: Int, todaySticks: Int, todayLimit: Int) -> [DayRecord] {
        var list = all.filter { $0.date != DailyState.today }
        list.append(DayRecord(date: DailyState.today, sticks: todaySticks, limit: todayLimit))
        return Array(list.suffix(days))
    }
}

// ── PIN store (Keychain, salted SHA-256) ──────────────────────────────────────
enum PinStore {
    private static let service = "iqos.admin"
    private static let account = "pin"
    private static let seedAccount = "pin.seed"
    /// Ίδιο salt με το deploy-ios.sh (που υπολογίζει το hash του τυχαίου PIN).
    private static let seedSalt = "iqoslimiter"
    /// Μήκος PIN (το pad και οι τελείες το διαβάζουν από εδώ).
    static let length = 6

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func hash(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    // ── Provisioned PIN (τυχαίο, ορίζεται στο build, ο χρήστης δεν το ξέρει) ──

    /// Αν το build έφερε hash PIN (Info.plist → AdminPinHash), το κρατάμε στο Keychain.
    /// Έτσι ένα μεταγενέστερο build χωρίς αυτό (π.χ. από το Xcode) δεν το καταργεί.
    static func adoptBundleSeed() {
        if let h = Bundle.main.object(forInfoDictionaryKey: "AdminPinHash") as? String,
           h.count == 64, h.allSatisfy({ $0.isHexDigit }) {
            write(h.lowercased(), account: seedAccount)
        }
    }

    static var hasSeed: Bool { read(seedAccount) != nil }

    // ── PIN ορισμένο από τον χρήστη (fallback όταν δεν υπάρχει seed) ──

    static var hasPin: Bool { read(account) != nil }

    static func set(_ pin: String) {
        let salt = UUID().uuidString
        write("\(salt):\(hash(pin, salt: salt))", account: account)
    }

    static func clear() { SecItemDelete(query(account) as CFDictionary) }

    static func verify(_ pin: String) -> Bool {
        if let seed = read(seedAccount) { return hash(pin, salt: seedSalt) == seed }
        guard let stored = read(account), let sep = stored.firstIndex(of: ":") else { return false }
        let salt = String(stored[..<sep])
        return hash(pin, salt: salt) == String(stored[stored.index(after: sep)...])
    }

    /// Μεταφέρει παλιό PIN από UserDefaults (plain text) στο Keychain.
    static func migrateLegacy(key: String) {
        let ud = UserDefaults.standard
        if let legacy = ud.string(forKey: key) {
            if !hasPin { set(legacy) }
            ud.removeObject(forKey: key)
        }
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
    /// Στάλθηκε ειδοποίηση αποσύνδεσης που περιμένει «επανασύνδεση»;
    private var pendingReconnectNotice = false
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
        PinStore.migrateLegacy(key: Self.pinKey)
        PinStore.adoptBundleSeed()
        observeAppActivity()
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
        DailyState.notifiedLimit = false
        DailyState.notifiedOneLeft = false
        Task { await evaluateLimit() }
    }

    // ── PIN ────────────────────────────────────────────────────────────────────

    /// Το προεπιλεγμένο PIN όταν δεν έχει οριστεί ακόμη.
    static let defaultPin = "0000"

    var hasCustomPin: Bool { PinStore.hasSeed || PinStore.hasPin }
    /// Το PIN είναι τυχαίο και ορίστηκε στο build — δεν αλλάζει από την εφαρμογή.
    var hasProvisionedPin: Bool { PinStore.hasSeed }

    private static let pinLastFailKey = "iqos.admin.lastFail"
    /// Μετά από τόσες αποτυχίες ισχύει αναμονή πριν την επόμενη προσπάθεια.
    private static let pinCooldownAfter = 3
    private static let pinCooldownSeconds: TimeInterval = 30
    /// Πόσο πρέπει να περάσει από την τελευταία αποτυχία για να επιτραπεί ο καθαρισμός.
    private static let pinResetWaitSeconds: TimeInterval = 15 * 60

    private var lastFailDate: Date? {
        let t = UserDefaults.standard.double(forKey: Self.pinLastFailKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Δευτερόλεπτα αναμονής πριν την επόμενη προσπάθεια (0 = ελεύθερο).
    var pinCooldownRemaining: Int {
        guard pinFailures >= Self.pinCooldownAfter, let last = lastFailDate else { return 0 }
        return max(0, Int((Self.pinCooldownSeconds - Date().timeIntervalSince(last)).rounded(.up)))
    }

    /// Δευτερόλεπτα μέχρι να επιτραπεί ο καθαρισμός (0 = διαθέσιμος).
    var resetWaitRemaining: Int {
        guard pinFailures >= Self.pinMaxFails else { return Int(Self.pinResetWaitSeconds) }
        guard let last = lastFailDate else { return 0 }
        return max(0, Int((Self.pinResetWaitSeconds - Date().timeIntervalSince(last)).rounded(.up)))
    }

    /// Ελέγχει κωδικό. Σωστό → admin. Λάθος → μετρητής + cooldown.
    @discardableResult
    func verifyPin(_ pin: String) -> Bool {
        guard pinCooldownRemaining == 0 else { return false }
        let ok = hasCustomPin ? PinStore.verify(pin) : pin == Self.defaultPin
        if ok {
            isAdmin = true
            pinFailures = 0
            UserDefaults.standard.set(0, forKey: Self.pinFailsKey)
            UserDefaults.standard.removeObject(forKey: Self.pinLastFailKey)
            return true
        }
        pinFailures += 1
        UserDefaults.standard.set(pinFailures, forKey: Self.pinFailsKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.pinLastFailKey)
        return false
    }

    var canResetPin: Bool { pinFailures >= Self.pinMaxFails && resetWaitRemaining == 0 }

    /// Κλείνει το admin mode (π.χ. όταν κλείσει το sheet).
    func endAdminSession() { isAdmin = false }

    func setNewPin(_ pin: String) {
        PinStore.set(pin)
        pinFailures = 0
        UserDefaults.standard.set(0, forKey: Self.pinFailsKey)
        UserDefaults.standard.removeObject(forKey: Self.pinLastFailKey)
        isAdmin = true
    }

    /// Recovery όταν έχασες τον κωδικό: καθαρισμός ρυθμίσεων + ξεκλείδωμα
    /// συσκευής, ώστε να μην μείνεις ποτέ μπλοκαρισμένος από το IQOS.
    func resetAdminAccess() {
        let ud = UserDefaults.standard
        PinStore.clear()
        ud.removeObject(forKey: Self.pinFailsKey)
        ud.removeObject(forKey: Self.pinLastFailKey)
        pinFailures = 0
        isAdmin = true

        // Καθαρισμός ημερήσιας κατάστασης
        ud.removeObject(forKey: DailyState.keyBaseline)
        ud.removeObject(forKey: DailyState.keyLastLifetime)
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
            DailyState.notifiedLimit = false
            DailyState.notifiedOneLeft = false

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

    /// Εκτελεί `work` με background-task assertion, ώστε το iOS να μη παγώσει το app στη μέση της μέτρησης.
    @MainActor
    private func runInBackgroundTask(_ work: @escaping () async -> Void) {
        #if os(iOS)
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "iqos-evaluate") {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        Task {
            await work()
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        }
        #else
        Task { await work() }
        #endif
    }

    /// Αξιολόγηση με επαναλήψεις: στο background, αμέσως μετά τη σύνδεση, η πρώτη ανάγνωση
    /// μπορεί να αποτύχει και δεν θα υπάρξει άλλος έλεγχος (οι timers δεν τρέχουν).
    @MainActor
    func evaluateWithRetry() {
        runInBackgroundTask { [weak self] in
            guard let self else { return }
            for attempt in 1...4 {
                if await self.evaluateLimit() { return }
                if attempt < 4 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }
        }
    }

    // ── Event log (για διάγνωση — φαίνεται στην κύρια οθόνη) ─────────────────
    @Published var eventLog: [String] = UserDefaults.standard.stringArray(forKey: "iqos.eventlog") ?? []

    func logEvent(_ text: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd/MM HH:mm:ss"
        var list = eventLog
        list.insert("\(fmt.string(from: Date()))  \(text)", at: 0)
        if list.count > 60 { list = Array(list.prefix(60)) }
        eventLog = list
        UserDefaults.standard.set(list, forKey: "iqos.eventlog")
    }

    /// Εκκίνηση αξιολόγησης με καθυστέρηση — ακυρώνει οποιαδήποτε προηγούμενη αναμονή
    @MainActor
    private func scheduleEvaluation(after delay: TimeInterval) {
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.evaluateWithRetry() }
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
    @discardableResult
    func evaluateLimit() async -> Bool {
        guard !isEvaluating else { return false }
        isEvaluating = true
        defer { isEvaluating = false; lastEvaluation = Date() }

        DailyState.resetIfNewDay()
        syncLimitFromStorage()

        guard let lifetimeCount = await readPuffCount() else {
            logEvent("δεν διαβάστηκε ο μετρητής")
            return false
        }

        lifetimePuffs = lifetimeCount
        if totalLifetimeSticks == 0 {
            setTotalLifetimeSticks(lifetimeCount)
        }

        // Ορισμός baseline αν είναι πρώτη φορά σήμερα ή αν το baseline είναι 0/άκυρο
        // Πρώτο evaluation της μέρας: ό,τι έγινε από την τελευταία φορά που είδε το app τον μετρητή
        // (π.χ. αποσύνδεση το βράδυ) ανήκει στην ΠΡΟΗΓΟΥΜΕΝΗ μέρα — δεν μπαίνει στη σημερινή.
        if DailyState.baseline == nil,
           let last = DailyState.lastLifetime,
           let prev = UserDefaults.standard.string(forKey: DailyState.keyPrevDate),
           lifetimeCount > last, lifetimeCount - last <= kMaxPlausibleDailyDiff {
            let gap = lifetimeCount - last
            UsageHistory.add(date: prev,
                             sticks: kCounterIsInSticks ? gap : Int((Double(gap) / kPuffsPerStick).rounded()))
        }
        var currentBaseline = DailyState.baseline ?? 0

        // Repair: το παλιό bug έγραφε baseline = 1 → τεράστια νούμερα. Ξαναβάζουμε baseline.
        if currentBaseline > 0 && lifetimeCount - currentBaseline > kMaxPlausibleDailyDiff {
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
        let sticksToday = kCounterIsInSticks ? diff : Int((Double(diff) / kPuffsPerStick).rounded())
        rawPuffsToday = diff
        currentStickProgress = 0

        let previousSticks = DailyState.puffsToday
        logEvent("μέτρηση: \(sticksToday) sticks (πριν \(previousSticks)), μετρητής \(lifetimeCount)")
        puffsToday = sticksToday
        DailyState.puffsToday = sticksToday
        DailyState.lastLifetime = lifetimeCount
        UsageHistory.record(date: DailyState.today, sticks: sticksToday, limit: dailyLimit)

        let remaining = max(0, dailyLimit - sticksToday)

        // Μία ειδοποίηση κάθε φορά που προστίθεται stick (και στο background, μόλις συνδεθεί το IQOS).
        let added = sticksToday - previousSticks
        if added > 0 {
            let what = added == 1 ? "Νέο stick" : "\(added) νέα sticks"
            if sticksToday > dailyLimit {
                sendNotification(title: "\(what) — πάνω από το όριο 🚫",
                                 body: "\(sticksToday)/\(dailyLimit) sticks σήμερα. Ξεπέρασες το όριο.")
            } else if sticksToday == dailyLimit {
                sendNotification(title: "Έφτασες το όριο 🚫",
                                 body: "\(sticksToday)/\(dailyLimit) sticks σήμερα. Το IQOS κλειδώνει.")
            } else if remaining == 1 {
                sendNotification(title: "\(what) — μένει μόνο 1 ⚠️",
                                 body: "\(sticksToday)/\(dailyLimit) sticks σήμερα.")
            } else {
                sendNotification(title: "\(what): \(sticksToday)/\(dailyLimit)",
                                 body: "Απομένουν \(remaining) για σήμερα.")
            }
        }

        if sticksToday >= dailyLimit {
            statusMessage = "🚫 Όριο! \(sticksToday)/\(dailyLimit) sticks"
            if !isLocked { await sendLock() }
        } else {
            statusMessage = "✅ \(sticksToday)/\(dailyLimit) sticks — Απομένουν \(remaining)"
            if isLocked { await sendUnlock() }  // νέα μέρα, ξεκλείδωμα
        }
        return true
    }

    // ── Notifications ─────────────────────────────────────────────────────────

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Όσο το app είναι ανοιχτό και ενεργό δεν στέλνουμε ειδοποιήσεις — η πληροφορία φαίνεται ήδη στην οθόνη.
    private var appIsActive = false

    private func observeAppActivity() {
        #if os(iOS)
        appIsActive = UIApplication.shared.applicationState == .active
        let active = UIApplication.didBecomeActiveNotification
        let resign = UIApplication.willResignActiveNotification
        #else
        appIsActive = NSApplication.shared.isActive
        let active = NSApplication.didBecomeActiveNotification
        let resign = NSApplication.willResignActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            self?.appIsActive = true
        }
        NotificationCenter.default.addObserver(forName: resign, object: nil, queue: .main) { [weak self] _ in
            self?.appIsActive = false
        }
    }

    private func sendNotification(title: String, body: String) {
        guard !appIsActive else {
            logEvent("ειδοποίηση (παραλείφθηκε, app ανοιχτό): \(title)")
            return
        }
        logEvent("ειδοποίηση: \(title)")
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

    /// Εκκρεμής σύνδεση (δεν λήγει ποτέ): το iOS συνδέει μόνο του όταν το IQOS ξαναεμφανιστεί
    /// και ξυπνά το app ακόμα κι αν είναι στο background. Οι timers δεν δουλεύουν σε suspended app,
    /// γι' αυτό δεν βασιζόμαστε σε σάρωση με timer.
    fileprivate func connectPending(_ central: CBCentralManager, _ peripheral: CBPeripheral) {
        reconnectTimer?.invalidate()
        iqosPeripheral      = peripheral
        peripheral.delegate = self
        connectionState     = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            // Γνωστό IQOS από προηγούμενη φορά → απευθείας (εκκρεμής) σύνδεση, χωρίς σάρωση
            if let idString = UserDefaults.standard.string(forKey: "iqos.peripheralID"),
               let id = UUID(uuidString: idString),
               let known = central.retrievePeripherals(withIdentifiers: [id]).first {
                statusMessage = "Σύνδεση με το IQOS..."
                connectPending(central, known)
            } else {
                startScanning()
            }
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
        logEvent("συνδέθηκε")
        connectionState    = .connected
        iqosPeripheral     = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "iqos.peripheralID")
        // Discover ALL services on IQOS ILUMA
        peripheral.discoverServices(nil)
        statusMessage = "Συνδεδεμένο! Ανακάλυψη υπηρεσιών..."
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        stopPolling()
        logEvent("αποσύνδεση\(error.map { " (\($0.localizedDescription))" } ?? "")")
        sendNotification(title: "Το IQOS αποσυνδέθηκε",
                         body: "Χωρίς σύνδεση δεν μπορεί να εφαρμοστεί το όριο. Θα σε ειδοποιήσω όταν συνδεθεί ξανά.")
        pendingReconnectNotice = true
        connectionState   = .disconnected
        controlChar       = nil
        notifyChar        = nil
        statusMessage     = "Αποσυνδέθηκε — περιμένω να επανέλθει..."
        // Εκκρεμής σύνδεση: δουλεύει και στο background
        connectPending(central, peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        stopPolling()
        // Ξαναδοκιμάζουμε σύντομα με εκκρεμή σύνδεση (και όχι με timer-σάρωση)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.connectPending(central, peripheral)
        }
    }

    // State restoration (background BLE)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral  = peripherals.first {
            iqosPeripheral      = peripheral
            peripheral.delegate = self
            // Το iOS ξύπνησε το app: αν το IQOS είναι συνδεδεμένο συνεχίζουμε, αλλιώς εκκρεμής σύνδεση
            if peripheral.state == .connected {
                connectionState = .connected
                peripheral.discoverServices(nil)
            } else {
                connectPending(central, peripheral)
            }
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
            if pendingReconnectNotice {
                pendingReconnectNotice = false
                sendNotification(title: "Το IQOS συνδέθηκε ξανά ✓",
                                 body: "Το όριο εφαρμόζεται ξανά κανονικά.")
            }
            logEvent("έτοιμο για εντολές")
            Task { @MainActor in self.evaluateWithRetry() }
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

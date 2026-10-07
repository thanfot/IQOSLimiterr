import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: IQOSBLEManager
    @State private var showLimitPicker = false
    @State private var tempLimit = 5
    @State private var showTotalPicker = false
    @State private var tempTotal = 8800
    @State private var showJSONSheet = false
    @State private var rawJSONText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    // ── Status Card ───────────────────────────────────────────
                    StatusCard(ble: ble)

                    // ── Progress Ring ─────────────────────────────────────────
                    ProgressRing(ble: ble)

                    // ── Stats Grid ────────────────────────────────────────────
                    StatsGrid(ble: ble)

                    // ── Actions ───────────────────────────────────────────────
                    ActionsSection(ble: ble, showLimitPicker: $showLimitPicker, tempLimit: $tempLimit, showTotalPicker: $showTotalPicker, tempTotal: $tempTotal, showJSONSheet: $showJSONSheet, rawJSONText: $rawJSONText)

                    // ── IQOS Device Controls & Settings ───────────────────────
                    DeviceSettingsSection(ble: ble)

                    // ── Debug: decoded telemetry fields ──────────────────────
                    TelemetryFieldsSection(ble: ble)

                }
                .padding()
            }
            .navigationTitle("IQOS Limiter")
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
#endif
            // Κρυφή είσοδος admin: 5 γρήγορα taps οπουδήποτε στο scroll
            .simultaneousGesture(
                TapGesture(count: 5).onEnded { ble.showPinPrompt = true }
            )
            .sheet(isPresented: $showLimitPicker) {
                LimitPickerSheet(limit: $tempLimit,
                                 todayLimit: ble.dailyLimit,
                                 nextDayLimit: ble.nextDayLimit,
                                 isAdmin: ble.isAdmin) {
                    ble.setNextDayLimit(tempLimit)
                    showLimitPicker = false
                }
            }
            .sheet(isPresented: $ble.showPinPrompt) {
                PinSheet(ble: ble)
            }
            .sheet(isPresented: $showTotalPicker) {
                TotalPickerSheet(total: $tempTotal) {
                    ble.setTotalLifetimeSticks(tempTotal)
                    showTotalPicker = false
                }
            }
            .sheet(isPresented: $showJSONSheet) {
                JSONInspectorSheet(jsonText: rawJSONText)
            }
        }
    }
}

// ── Status Card ───────────────────────────────────────────────────────────────
struct StatusCard: View {
    @ObservedObject var ble: IQOSBLEManager

    var connectionColor: Color {
        switch ble.connectionState {
        case .connected:    return .green
        case .scanning,
             .connecting:   return .orange
        default:            return .red
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(connectionColor)
                .frame(width: 12, height: 12)
                .shadow(color: connectionColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(ble.connectionState.label)
                    .font(.headline)
                Text(ble.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()

            if ble.isLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// ── Progress Ring ─────────────────────────────────────────────────────────────
struct ProgressRing: View {
    @ObservedObject var ble: IQOSBLEManager

    var current: Int { ble.puffsToday }
    var limit: Int   { ble.dailyLimit }

    var progress: Double { min(Double(current) / Double(max(limit, 1)), 1.0) }
    var remaining: Int   { max(limit - current, 0) }
    var isOver: Bool     { current >= limit }

    var ringColor: Color {
        if isOver                     { return .red }
        if Double(current) / Double(limit) > 0.7 { return .orange }
        return .green
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor.opacity(0.15), lineWidth: 20)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: progress)

            VStack(spacing: 4) {
                Text("\(current)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(ringColor)
                Text("/ \(limit) sticks")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !isOver {
                    Text("Απομένουν \(remaining)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Όριο!")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
        }
        .frame(width: 220, height: 220)
        .padding()
    }
}

// ── Stats Grid ────────────────────────────────────────────────────────────────
struct StatsGrid: View {
    @ObservedObject var ble: IQOSBLEManager

    var remaining: Int {
        max(0, ble.dailyLimit - ble.puffsToday)
    }

    var totalSticksDisplay: String {
        let total = ble.totalLifetimeSticks > 0 ? ble.totalLifetimeSticks : ble.lifetimePuffs
        return total > 0 ? "\(total)" : "--"
    }

    let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            StatTile(
                icon: "flame.fill",
                color: .orange,
                title: "Σήμερα",
                value: "\(ble.puffsToday)"
            )
            StatTile(
                icon: "hourglass",
                color: .blue,
                title: "Απομένουν",
                value: "\(remaining)"
            )
            StatTile(
                icon: "calendar",
                color: .purple,
                title: "Όριο/μέρα",
                value: "\(ble.dailyLimit)"
            )
            StatTile(
                icon: "leaf.fill",
                color: .green,
                title: "Σύνολο Τερέα",
                value: totalSticksDisplay
            )
        }
    }
}

struct StatTile: View {
    let icon: String
    let color: Color
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title3.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// ── Actions Section ───────────────────────────────────────────────────────────
struct ActionsSection: View {
    @ObservedObject var ble: IQOSBLEManager
    @Binding var showLimitPicker: Bool
    @Binding var tempLimit: Int
    @Binding var showTotalPicker: Bool
    @Binding var tempTotal: Int
    @Binding var showJSONSheet: Bool
    @Binding var rawJSONText: String

    var body: some View {
        VStack(spacing: 12) {
            // Χειροκίνητο Κλείδωμα / Ξεκλείδωμα
            if ble.connectionState == .connected {
                HStack(spacing: 12) {
                    Button {
                        ble.manualLock()
                    } label: {
                        Label("Κλείδωμα", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.red)
                    }

                    Button {
                        ble.manualUnlock()
                    } label: {
                        Label("Ξεκλείδωμα", systemImage: "lock.open.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.green)
                    }
                }
            }

            // Ανανέωση μετρητή & Αλλαγή ορίου
            if ble.connectionState == .connected {
                HStack(spacing: 12) {
                    Button {
                        ble.manualRefresh()
                    } label: {
                        Label("Ανανέωση", systemImage: "arrow.clockwise.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.purple)
                    }

                    Button {
                        ble.resetTodayBaseline()
                    } label: {
                        Label("Μηδενισμός Ημέρας", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    tempLimit = ble.nextDayLimit
                    showLimitPicker = true
                } label: {
                    Label("Ημερήσιο Όριο", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.blue)
                }

                Button {
                    tempTotal = ble.totalLifetimeSticks > 0 ? ble.totalLifetimeSticks : (ble.lifetimePuffs > 0 ? ble.lifetimePuffs : 8800)
                    showTotalPicker = true
                } label: {
                    Label("Σύνολο Τερέα", systemImage: "pencil.line")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.green)
                }
            }

            Button {
                rawJSONText = ble.exportRawDeviceData()
                showJSONSheet = true
            } label: {
                Label("📋 Πληροφορίες IQOS (Raw JSON)", systemImage: "curlybraces.square.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.primary)
            }

            // Reconnect
            if ble.connectionState == .disconnected || ble.connectionState == .idle {
                Button {
                    ble.startScanning()
                } label: {
                    Label("Εκ νέου σύνδεση", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

// ── Limit Picker Sheet ────────────────────────────────────────────────────────
struct LimitPickerSheet: View {
    @Binding var limit: Int
    let todayLimit: Int
    let nextDayLimit: Int
    let isAdmin: Bool
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Το σημερινό όριο δεν αλλάζει εκτός admin mode
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Σήμερα")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(todayLimit) sticks")
                            .font(.title3.bold())
                    }
                    Spacer()
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                Text(isAdmin ? "Νέο όριο — ισχύει άμεσα (admin)"
                             : "Νέο όριο — ισχύει από αύρια")
                    .font(.headline)
                    .foregroundStyle(isAdmin ? .green : .secondary)

                Picker("Ημερήσιο όριο", selection: $limit) {
                    ForEach(1...100, id: \.self) { n in
                        Text("\(n) sticks").tag(n)
                    }
                }
#if os(iOS)
                .pickerStyle(.wheel)
#else
                .pickerStyle(.menu)
#endif
                .frame(height: 150)

                if !isAdmin {
                    Text("Χωρίς κωδικό η αλλαγή κλειδώνεται για τη σημερινή ημέρα. "
                         + "Πάτα 5 taps για κωδικό.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Αποθήκευση") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
            .navigationTitle("Ημερήσιο Όριο")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .presentationDetents([.medium])
    }
}

// ── Total Terea Picker Sheet ──────────────────────────────────────────────────
struct TotalPickerSheet: View {
    @Binding var total: Int
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Συνολικά Τερέα που έχεις κάνει")
                    .font(.title2.bold())

                HStack {
                    TextField("Αριθμός Τερέα", value: $total, format: .number)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                Text("Ο μετρητής αυξάνεται αυτόματα κατά +1 κάθε φορά που τοποθετείτε το στυλό στο φορτιστή.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Αποθήκευση") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
            .navigationTitle("Σύνολο Τερέα")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .presentationDetents([.medium])
    }
}

// ── Device Settings Section ───────────────────────────────────────────────────
struct DeviceSettingsSection: View {
    @ObservedObject var ble: IQOSBLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("🎛️ Ρυθμίσεις Συσκευής IQOS")
                .font(.headline)
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "bolt.circle.fill")
                        .foregroundStyle(.yellow)
                    Toggle("Pause Mode (FlexBattery)", isOn: Binding(
                        get: { ble.pauseModeEnabled },
                        set: { ble.togglePauseMode($0) }
                    ))
                    .font(.callout)
                }

                Divider()

                HStack {
                    Image(systemName: "wind")
                        .foregroundStyle(.blue)
                    Toggle("FlexPuff", isOn: Binding(
                        get: { ble.flexPuffEnabled },
                        set: { ble.toggleFlexPuff($0) }
                    ))
                    .font(.callout)
                }

                Divider()

                HStack {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                    Toggle("Autostart (Αυτόματη θέρμανση)", isOn: Binding(
                        get: { ble.autostartEnabled },
                        set: { ble.toggleAutostart($0) }
                    ))
                    .font(.callout)
                }

                Divider()

                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.purple)
                    Toggle("Δονήσεις (Vibration)", isOn: Binding(
                        get: { ble.vibrationEnabled },
                        set: { ble.toggleVibration($0) }
                    ))
                    .font(.callout)
                }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

// ── Decoded Telemetry Fields (debug) ─────────────────────────────────────────
struct TelemetryFieldsSection: View {
    @ObservedObject var ble: IQOSBLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("🔬 Αποκωδικοποιημένα πεδία")
                    .font(.headline)
                if ble.telemetryFields.isEmpty {
                    Text("(κανένα)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !ble.telemetryFields.isEmpty {
                ForEach(ble.telemetryFields) { field in
                    HStack {
                        Text(field.tagHex)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(field.tagHex == "0x8E" ? .green : .secondary)
                        Spacer()
                        Text("\(field.value)")
                            .font(.system(.caption, design: .monospaced))
                            .bold()
                            .foregroundStyle(field.tagHex == "0x8E" ? .green : .primary)
                    }
                }

                Text("Το πράσινο tag (0x8E) είναι το puff count. Κάπνισε 1 τερέα και δες ποιο tag αλλάζει.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// ── JSON Inspector Sheet ──────────────────────────────────────────────────────
struct JSONInspectorSheet: View {
    let jsonText: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Όλα τα ακατέργαστα δεδομένα & καταχωρητές του IQOS:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(jsonText)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.85))
                        .foregroundStyle(Color.green)
                        .cornerRadius(12)
                }
                .padding()
            }
            .navigationTitle("IQOS Raw JSON")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Αντιγραφή") {
#if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(jsonText, forType: .string)
#else
                        UIPasteboard.general.string = jsonText
#endif
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Κλείσιμο") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// ── Admin PIN Sheet ───────────────────────────────────────────────────────────
/// Κλειδιο του διαχειριστή: 5 taps οπουδήποτε → κωδικός.
/// Χωρίς κωδικό το όριο αλλάζει μόνο για αύρια και το lock/unlock είναι αποκλεισμένο.
struct PinSheet: View {
    @ObservedObject var ble: IQOSBLEManager

    private enum Mode { case entry, setNew, resetConfirm }

    @State private var mode: Mode = .entry
    @State private var entry = ""
    @State private var firstPin = ""
    @State private var message: String?
    @State private var authed = false

    private var title: String {
        switch mode {
        case .entry:        return "Κωδικός διαχειριστή"
        case .setNew:       return "Νέος κωδικός"
        case .resetConfirm: return "Καθαρισμός"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch mode {
                case .entry:
                    dots
                case .setNew:
                    Text(firstPin.isEmpty ? "Βάλε 4 νούμερα" : "Ξανά για επιβεβαίωση")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    dots
                case .resetConfirm:
                    resetConfirm
                }

                if mode != .resetConfirm {
                    keypad
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                if mode == .entry && ble.canResetPin {
                    Button("Ξέχασες τον κωδικό;") {
                        mode = .resetConfirm
                        entry = ""
                        message = nil
                    }
                    .font(.footnote)
                    .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle(title)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Κλείσιμο") { close(success: authed) }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear { entry = ""; message = nil }
    }

    // ── Pieces ────────────────────────────────────────────────────────────────

    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .strokeBorder(.secondary)
                    .background(Circle().fill(i < entry.count ? Color.accentColor : .clear))
                    .frame(width: 18, height: 18)
            }
        }
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
            ForEach(["1","2","3","4","5","6","7","8","9","·","0","⌫"], id: \.self) { key in
                if key == "·" {
                    Color.clear.frame(height: 56)
                } else {
                    Button { tap(key) } label: {
                        Text(key)
                            .font(.title2.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var resetConfirm: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Καθαρισμός ρυθμίσεων")
                .font(.headline)
            Text("Χάνεις τον μετρητή της ημέρας και ο κωδικός μηδενίζεται. "
                 + "Το IQOS ξεκλειδώνεται — δεν μπορείς να μείνεις μπλοκαρισμένος.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Ακύρωση") {
                    mode = .entry
                    message = nil
                }
                .buttonStyle(.bordered)

                Button("Επιβεβαίωση", role: .destructive) {
                    ble.resetAdminAccess()
                    firstPin = ""
                    entry = ""
                    mode = .setNew
                    message = "Ορίσε νέο 4ψήφιο κωδικό"
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // ── Logic ─────────────────────────────────────────────────────────────────

    private func tap(_ key: String) {
        switch key {
        case "⌫":
            if !entry.isEmpty { entry.removeLast(); message = nil }
        case "·":
            break
        default:
            guard entry.count < 4 else { return }
            entry.append(key)
            message = nil
            if entry.count == 4 { submit() }
        }
    }

    private func submit() {
        switch mode {
        case .entry:
            if ble.verifyPin(entry) {
                authed = true
                entry = ""
                close(success: true)
            } else {
                entry = ""
                message = "Λάθος κωδικός — προσπάθεια \(ble.pinFailures)/\(IQOSBLEManager.pinMaxFails)"
            }

        case .setNew:
            if firstPin.isEmpty {
                firstPin = entry
                entry = ""
                message = "Ξανά τα ίδια 4 νούμερα"
            } else if entry == firstPin {
                ble.setNewPin(entry)
                authed = true
                firstPin = ""; entry = ""
                close(success: true)
            } else {
                firstPin = ""; entry = ""
                message = "Δεν ταιριάζουν — ξανά από την αρχή"
            }

        case .resetConfirm:
            break
        }
    }

    private func close(success: Bool) {
        if !success { ble.endAdminSession() }
        ble.showPinPrompt = false
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(IQOSBLEManager())
    }
}

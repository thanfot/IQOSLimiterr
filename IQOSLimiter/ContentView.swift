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

                }
                .padding()
            }
            .navigationTitle("IQOS Limiter")
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
#endif
            .sheet(isPresented: $showLimitPicker) {
                LimitPickerSheet(limit: $tempLimit) {
                    ble.setDailyLimit(tempLimit)
                    showLimitPicker = false
                }
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
                if ble.rawPuffsToday > 0 {
                    Text("(\(ble.rawPuffsToday) puffs)")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
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
                title: ble.rawPuffsToday > 0 ? "Σήμερα (\(ble.rawPuffsToday) puffs)" : "Σήμερα",
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

            // Χειροκίνητη Προσθήκη / Αφαίρεση Stick
            HStack(spacing: 12) {
                Button {
                    ble.addStick()
                } label: {
                    Label("+1 Stick", systemImage: "plus.circle.fill")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.orange)
                }

                Button {
                    ble.removeStick()
                } label: {
                    Label("-1 Stick", systemImage: "minus.circle.fill")
                        .font(.callout.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.secondary)
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
                    tempLimit = ble.dailyLimit
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
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Text("Πόσα sticks την ημέρα;")
                    .font(.title2.bold())

                Picker("Ημερήσιο όριο", selection: $limit) {
                    ForEach(1...20, id: \.self) { n in
                        Text("\(n) sticks").tag(n)
                    }
                }
#if os(iOS)
                .pickerStyle(.wheel)
#else
                .pickerStyle(.menu)
#endif
                .frame(height: 180)

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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(IQOSBLEManager())
    }
}

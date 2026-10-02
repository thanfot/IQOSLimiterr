import SwiftUI

struct ContentView: View {
    @EnvironmentObject var ble: IQOSBLEManager
    @State private var showLimitPicker = false
    @State private var tempLimit = 5

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    // ── Status Card ───────────────────────────────────────────
                    StatusCard(ble: ble)

                    // ── Progress Ring ─────────────────────────────────────────
                    ProgressRing(current: ble.puffsToday, limit: ble.dailyLimit)

                    // ── Stats Grid ────────────────────────────────────────────
                    StatsGrid(ble: ble)

                    // ── Actions ───────────────────────────────────────────────
                    ActionsSection(ble: ble, showLimitPicker: $showLimitPicker, tempLimit: $tempLimit)

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
    let current: Int
    let limit: Int

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

    var body: some View {
        HStack(spacing: 12) {
            StatTile(
                icon: "flame.fill",
                color: .orange,
                title: "Σήμερα",
                value: "\(ble.puffsToday)"
            )
            StatTile(
                icon: "infinity",
                color: .blue,
                title: "Σύνολο",
                value: "\(ble.lifetimePuffs)"
            )
            StatTile(
                icon: "calendar",
                color: .purple,
                title: "Όριο/μέρα",
                value: "\(ble.dailyLimit)"
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
                Button {
                    ble.manualRefresh()
                } label: {
                    Label("Ανανέωση Μετρητή Sticks", systemImage: "arrow.clockwise.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.purple)
                }
            }

            Button {
                tempLimit = ble.dailyLimit
                showLimitPicker = true
            } label: {
                Label("Αλλαγή ημερήσιου ορίου", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.blue)
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

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(IQOSBLEManager())
    }
}

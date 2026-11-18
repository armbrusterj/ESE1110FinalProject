import SwiftUI

// MARK: - Color helpers

extension Color {
    /// A color from 0–255 DMX channel values.
    init(dmxRed r: Int, green g: Int, blue b: Int) {
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// The color as 0–255 sRGB components.
    func dmxComponents(in environment: EnvironmentValues) -> (red: Int, green: Int, blue: Int) {
        let cg = resolve(in: environment).cgColor
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let comps = cg.converted(to: srgb, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
        func byte(_ i: Int) -> Int {
            guard comps.count > i else { return 0 }
            return Int((min(max(comps[i], 0), 1) * 255).rounded())
        }
        return (byte(0), byte(1), byte(2))
    }

    /// A distinct color for shading the n-th fixture of the patch (in address
    /// order). Golden-ratio hue steps keep neighboring fixtures far apart.
    static func patchColor(index: Int) -> Color {
        let hue = (0.58 + Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.55, brightness: 0.9)
    }

    /// A tint for well-known channel names; anything else gets the accent color.
    static func channelTint(_ name: String) -> Color {
        switch name.lowercased() {
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "white": return .gray
        case "amber": return .orange
        case "uv": return .purple
        default: return .accentColor
        }
    }
}

extension Fixture {
    /// What the fixture looks like, for color fixtures. White (if any) brightens it.
    var previewColor: Color? {
        guard let rgb = rgbChannelIndices else { return nil }
        let w = whiteChannelIndex.map { values[$0] } ?? 0
        func v(_ i: Int) -> Int { min(255, (values.indices.contains(i) ? values[i] : 0) + w) }
        return Color(dmxRed: v(rgb.red), green: v(rgb.green), blue: v(rgb.blue))
    }
}

// MARK: - Small shared views

struct ColorSwatch: View {
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(color)
            .overlay(RoundedRectangle(cornerRadius: size / 4).strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ConnectionStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            switch model.connection {
            case .notConfigured:
                Circle().fill(.gray).frame(width: 10, height: 10)
                Text("No controller set")
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting to \(model.addressText)…")
            case .connected(let info):
                Circle().fill(.green).frame(width: 10, height: 10)
                Text("\(info.name) \(info.firmware) · \(model.addressText)")
            case .unreachable:
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("Unreachable · \(model.addressText)")
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// Always-reachable blackout. Added to the toolbar of every screen.
struct BlackoutButton: View {
    @Environment(AppModel.self) private var model
    @State private var working = false

    var body: some View {
        Button(role: .destructive) {
            working = true
            Task {
                await model.blackout()
                working = false
            }
        } label: {
            Label("Blackout", systemImage: "lightbulb.slash.fill")
        }
        .tint(.red)
        .disabled(working || !model.connection.isConnected)
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .help("Set every channel to 0")
    }
}

extension View {
    /// Adds the always-reachable blackout button to a screen's toolbar.
    func controllerChrome() -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) { BlackoutButton() }
        }
    }

    /// Shows `AppModel.lastError` (failed fader/blackout requests) once, app-wide.
    func controllerErrorAlert(_ model: AppModel) -> some View {
        alert(
            "The controller said no",
            isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } }),
            presenting: model.lastError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error.serverMessage ?? error.localizedDescription)
        }
    }
}

/// Number entry for a DMX address or value.
struct NumberField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: $value, format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .labelsHidden()
            Stepper(title, value: $value, in: range)
                .labelsHidden()
        }
    }
}

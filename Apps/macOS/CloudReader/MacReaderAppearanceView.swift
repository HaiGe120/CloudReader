import AppKit
import CloudReaderCore
import SwiftUI

struct MacReaderAppearanceView: View {
    let supportsTypography: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage("reader.pageLayout") private var pageLayoutRaw = "scroll"
    @AppStorage("reader.theme") private var themeRaw = "system"
    @AppStorage("reader.font") private var fontRaw = "systemSerif"
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.customBackground") private var customBackground = "F8F4EB"
    @AppStorage("reader.customForeground") private var customForeground = "292621"

    private var backgroundColor: Binding<Color> {
        Binding(
            get: { MacReaderColors.color(hex: customBackground) },
            set: { customBackground = MacReaderColors.hex($0) }
        )
    }

    private var foregroundColor: Binding<Color> {
        Binding(
            get: { MacReaderColors.color(hex: customForeground) },
            set: { customForeground = MacReaderColors.hex($0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Page layout") {
                    Picker("Layout", selection: $pageLayoutRaw) {
                        Text("Scroll").tag("scroll")
                        Text("Single page").tag("singlePage")
                        Text("Two pages").tag("facingPages")
                    }
                    .pickerStyle(.segmented)
                    Text("Two pages appear side by side when the reader window is wide enough.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Page color") {
                    Picker("Theme", selection: $themeRaw) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Sepia").tag("sepia")
                        Text("Dark").tag("dark")
                        Text("Custom").tag("custom")
                    }
                    if themeRaw == "custom" {
                        ColorPicker("Paper", selection: backgroundColor, supportsOpacity: false)
                        ColorPicker("Text", selection: foregroundColor, supportsOpacity: false)
                    }
                }

                if supportsTypography {
                  Section("Typography") {
                    Picker("Font", selection: $fontRaw) {
                        Text("New York").tag("systemSerif")
                        Text("System Sans").tag("systemSans")
                        Text("Rounded").tag("rounded")
                        Text("Georgia").tag("georgia")
                        Text("Palatino").tag("palatino")
                        Text("Avenir Next").tag("avenir")
                        Text("Monospaced").tag("monospaced")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text size")
                            Spacer()
                            Text("\(Int(fontSize)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $fontSize, in: 15...30, step: 1)
                    }
                  }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Reading Appearance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

enum MacReaderColors {
    static func color(hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let value = UInt64(cleaned, radix: 16) else { return .white }
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    static func hex(_ color: Color) -> String {
        let color = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        return String(
            format: "%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255)
        )
    }
}

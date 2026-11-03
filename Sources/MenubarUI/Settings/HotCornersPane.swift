import AppKit
import MenubarCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Hot Corners (HOT-01): the switch, a drawing of the screen with what each corner does, and under it the
/// editor of the selected corner: its delay and one action for the corner alone and one for each modifier held.
///
/// The drawing is the way in: a click on a corner's tile selects it. While the switch is off the drawing is dimmed but
/// still editable, so the corners can be set up before they go on. It draws only what it is given.
public struct HotCornersSettingsForm: View {
    @Binding private var preferences: Preferences
    private let isLegacyAppRunning: Bool
    private let shortcutNames: [String]
    private let onQuitLegacy: () -> Void
    private let onTryGlow: (HotCorner) -> Void
    @ViewState private var selected: HotCorner

    /// - Parameters:
    ///   - preferences: the preferences; a change saves at once
    ///   - isLegacyAppRunning: whether the old Hot Corners app runs, so both fire on the same corner
    ///   - shortcutNames: the user's shortcuts for Run Shortcut, as `shortcuts list` prints them
    ///   - onQuitLegacy: asks the old app to quit
    ///   - onTryGlow: shows the real glow at a corner of the main display
    ///   - selected: the corner the editor starts with, for the gallery
    public init(
        preferences: Binding<Preferences>, isLegacyAppRunning: Bool = false, shortcutNames: [String] = [],
        onQuitLegacy: @escaping () -> Void = {}, onTryGlow: @escaping (HotCorner) -> Void = { _ in },
        selected: HotCorner = .topLeft
    ) {
        self.onTryGlow = onTryGlow
        _preferences = preferences
        self.isLegacyAppRunning = isLegacyAppRunning
        self.shortcutNames = shortcutNames
        self.onQuitLegacy = onQuitLegacy
        _selected = ViewState(initialValue: selected)
    }

    private var settings: Binding<HotCornerSettings> {
        $preferences.hotCorners
    }

    public var body: some View {
        Form {
            SettingsPaneHeader(pane: .hotCorners)
            Section {
                Toggle(isOn: settings.enabled) {
                    SettingsRowLabel("Mega Corners", "Move the pointer into a screen corner to run its action")
                }
                .settingsSwitch()
                .settingsAnchor(.hotCorners)
                if isLegacyAppRunning {
                    StatusLine(.problem, "The Hot Corners app is running too, so both fire on the same corner.") {
                        Button("Quit Hot Corners", action: onQuitLegacy)
                    }
                }
            }
            Section {
                HotCornersScreen(
                    settings: preferences.hotCorners, selected: selected, select: { selected = $0 }
                )
                .listRowInsets(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
            }
            Section {
                delayRow
                ForEach(HotCornerSlot.all, id: \.self) { slot in
                    actionRow(slot)
                }
            } header: {
                SettingsSectionHeader("\(selected.title) Corner")
            } footer: {
                SettingsFooter(
                    "Hold ⌘, ⌥, ⌃ or ⇧ as the pointer reaches the corner to run its other action. "
                        + "Nothing fires while a mouse button is down. Corners between two displays don't count.")
            }
            glowSection
        }
        .formStyle(.grouped)
        .revealsSettingsFields()
    }

    // MARK: Corner glow

    private var glowSection: some View {
        let glow = settings.glow
        let isOn = preferences.hotCorners.glow.enabled
        return Section {
            Toggle(isOn: glow.enabled) {
                SettingsRowLabel("Corner Glow", "A soft light in the corner when its action fires")
            }
            .settingsSwitch()
            LabeledContent {
                HotCornerGlowColorPicker(color: glow.color)
            } label: {
                SettingsRowLabel("Color")
            }
            .disabled(!isOn)
            LabeledContent {
                Picker("Animation", selection: glow.style) {
                    ForEach(HotCornerGlowStyle.allCases, id: \.self) { style in
                        Text(verbatim: style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingsRowLabel("Animation", "Glow fades, Pulse beats twice, Ripple spreads in rings")
            }
            .disabled(!isOn)
            LabeledContent {
                HotCornerGlowSlider(
                    value: glow.duration, range: HotCornerGlow.durationRange, step: HotCornerGlow.durationStep
                ) { String(format: "%.1f s", $0) }
            } label: {
                SettingsRowLabel("Duration", "How long the animation plays")
            }
            .disabled(!isOn)
            LabeledContent {
                HotCornerGlowSlider(value: glow.opacity, range: HotCornerGlow.opacityRange, step: 0.05) {
                    "\(Int(($0 * 100).rounded()))%"
                }
            } label: {
                SettingsRowLabel("Opacity", "How bright the light is")
            }
            .disabled(!isOn)
            LabeledContent {
                Picker("Size", selection: glow.size) {
                    ForEach(HotCornerGlowSize.allCases, id: \.self) { size in
                        Text(verbatim: size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } label: {
                SettingsRowLabel("Size", "How far the light reaches into the screen")
            }
            .disabled(!isOn)
            LabeledContent {
                Button("Try on Screen") { onTryGlow(selected) }
                    .help("Plays the glow in the \(selected.title.lowercased()) corner of your main display")
            } label: {
                SettingsRowLabel("Try It", "In the \(selected.title.lowercased()) corner of the main display")
            }
            .disabled(!isOn)
        } header: {
            SettingsSectionHeader("Corner Glow")
        }
    }

    // MARK: Rows

    private var delayRow: some View {
        let corner = selected
        let delay = Binding(
            get: { preferences.hotCorners[corner].delay }, set: { preferences.hotCorners[corner].delay = $0 })
        var options = HotCornerSettings.delayOptions
        if !options.contains(delay.wrappedValue) {
            options.append(delay.wrappedValue)
            options.sort()
        }
        return LabeledContent {
            Picker("Delay", selection: delay) {
                ForEach(options, id: \.self) { value in
                    Text(verbatim: HotCornerText.delay(value)).tag(value)
                }
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            SettingsRowLabel("Delay", "How long the pointer rests in the corner first")
        }
    }

    private func actionRow(_ slot: HotCornerSlot) -> some View {
        let corner = selected
        let action = Binding(
            get: { preferences.hotCorners[corner][slot.modifier] },
            set: { preferences.hotCorners[corner][slot.modifier] = $0 })
        return LabeledContent {
            HotCornerActionMenu(action: action, shortcutNames: shortcutNames)
        } label: {
            HStack(spacing: 10) {
                HotCornerKeycap(modifier: slot.modifier)
                SettingsRowLabel(
                    slot.title,
                    action.wrappedValue == .system(.disableScreenSaver) ? "Lasts while the pointer stays in the corner." : nil)
            }
        }
    }
}

/// The plain slot or one modifier: the five rows of a corner's editor.
struct HotCornerSlot: Hashable {
    /// nil is the corner alone
    let modifier: HotCornerModifier?

    static let all: [HotCornerSlot] = [HotCornerSlot(modifier: nil)] + HotCornerModifier.allCases.map { HotCornerSlot(modifier: $0) }

    var title: String {
        modifier.map(\.title) ?? "Corner Only"
    }
}

// MARK: - Words

enum HotCornerText {
    /// "Instant", "0.15 s", "1 s"
    static func delay(_ seconds: Double) -> String {
        if seconds <= 0 { return "Instant" }
        let text = seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%g", seconds)
        return "\(text) s"
    }

    /// An app's name from its bundle's path: "Mail" for `/System/Applications/Mail.app`.
    static func appName(at path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

extension HotCornerAction {
    /// the action's name in the menus and on the tiles; a shortcut's name is trimmed here and stored verbatim
    var uiTitle: String {
        switch self {
        case .none: "No Action"
        case .system(let action): action.title
        case .openSection(let section): section.title
        case .showMainWindow: "MegaMonitor"
        case .search: "Search…"
        case .refreshNow: "Refresh Now"
        case .muteAlerts: "Mute Alerts for 1 Hour"
        case .runShortcut(let name): name.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openApp(let path): HotCornerText.appName(at: path)
        }
    }

    /// the action's SF Symbol; an app's own icon is drawn instead (see ``HotCornerActionIcon``)
    var uiSymbol: String {
        switch self {
        case .none: "circle.dashed"
        case .system(let action): action.symbolName
        case .openSection(let section): section.systemImage
        case .showMainWindow: "macwindow"
        case .search: "magnifyingglass"
        case .refreshNow: "arrow.clockwise"
        case .muteAlerts: "bell.slash"
        case .runShortcut: "square.stack.3d.up.fill"
        case .openApp: "app"
        }
    }
}

// MARK: - Pieces

/// An action's icon: its symbol, or the app's own icon for Open App.
struct HotCornerActionIcon: View {
    let action: HotCornerAction
    var size: CGFloat = 14

    var body: some View {
        if case .openApp(let path) = action {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: size + 2, height: size + 2)
        } else {
            Image(systemName: action.uiSymbol)
                .font(.system(size: size - 2, weight: .medium))
                .frame(width: size + 2, height: size + 2)
        }
    }
}

/// A modifier's key as a small keycap; the corner alone gets a pointer.
struct HotCornerKeycap: View {
    let modifier: HotCornerModifier?

    var body: some View {
        Group {
            if let modifier {
                Text(verbatim: modifier.symbol)
                    .font(.system(size: 14, weight: .medium))
            } else {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: 28, height: 24)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// The pop-up of one slot: No Action, the macOS actions, MegaMonitor's own, Run Shortcut and Open App….
struct HotCornerActionMenu: View {
    @Binding var action: HotCornerAction
    let shortcutNames: [String]

    private static let systemActions = SystemCornerAction.allCases

    var body: some View {
        Menu {
            Button {
                action = .none
            } label: {
                Label("No Action", systemImage: HotCornerAction.none.uiSymbol)
            }
            Divider()
            Section("macOS") {
                ForEach(Self.systemActions, id: \.self) { system in
                    item(.system(system))
                }
            }
            Section("MegaMonitor") {
                ForEach(HotCornerAction.appActions, id: \.self) { item($0) }
            }
            Divider()
            Menu {
                if shortcutNames.isEmpty {
                    Text("No Shortcuts Found")
                } else {
                    ForEach(shortcutNames, id: \.self) { name in
                        Button(name.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            action = .runShortcut(name: name)
                        }
                    }
                }
            } label: {
                Label("Run Shortcut", systemImage: HotCornerAction.runShortcut(name: "").uiSymbol)
            }
            Button {
                chooseApp()
            } label: {
                Label("Open App…", systemImage: "app")
            }
        } label: {
            HStack(spacing: 6) {
                HotCornerActionIcon(action: action)
                Text(verbatim: action.uiTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(action == .none ? .secondary : .primary)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func item(_ value: HotCornerAction) -> some View {
        Button {
            action = value
        } label: {
            Label(value.uiTitle, systemImage: value.uiSymbol)
        }
    }

    /// Asks for an app, starting in Applications.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            action = .openApp(path: url.path)
        }
    }
}

// MARK: - The glow's color

/// The swatches of the glow's colors: the accent and the presets, and a color well for one of the user's own.
struct HotCornerGlowColorPicker: View {
    @Binding var color: HotCornerGlowColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HotCornerGlowColor.presets, id: \.self) { preset in
                swatch(preset)
            }
            customWell
        }
    }

    /// The color well as a round swatch like the others: a rainbow until the user picks a color, then that color. The
    /// system's well (a wide pill) sits on top, invisible, so a click opens the color panel.
    private var customWell: some View {
        let fill: AnyShapeStyle =
            isCustom
            ? AnyShapeStyle(color.swiftUIColor.gradient)
            : AnyShapeStyle(
                AngularGradient(
                    colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center))
        return Circle()
            .fill(fill)
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .overlay { ring(isSelected: isCustom) }
            .padding(2)
            .overlay {
                ColorPicker("Custom color", selection: custom, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 22, height: 22)
                    .clipped()
                    .opacity(0.02)
            }
            .help("A color of your own")
            .accessibilityLabel("Custom color")
            .accessibilityAddTraits(isCustom ? .isSelected : [])
    }

    private var isCustom: Bool {
        if case .custom = color { return true }
        return false
    }

    private func swatch(_ preset: HotCornerGlowColor) -> some View {
        Button {
            color = preset
        } label: {
            swatchFill(preset)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .overlay { ring(isSelected: color == preset) }
                .padding(2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(preset == .accent ? "Accent: follows the color of System Settings" : preset.title)
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(color == preset ? .isSelected : [])
    }

    /// A preset's disc. The accent is split by a hairline, its color on one side and a neutral on the other, like the
    /// Auto choice of the system's appearance: it follows the system's setting, so it can look like Blue.
    @ViewBuilder
    private func swatchFill(_ preset: HotCornerGlowColor) -> some View {
        if preset == .accent {
            ZStack {
                Circle().fill(preset.swiftUIColor.gradient)
                HotCornerHalfDisc()
                    .fill(LinearGradient(colors: [.white.opacity(0.95), .gray.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                Rectangle().fill(.white.opacity(0.55)).frame(width: 18, height: 0.8).rotationEffect(.degrees(45))
            }
            .clipShape(Circle())
        } else {
            Circle().fill(preset.swiftUIColor.gradient)
        }
    }

    /// the mark of the chosen one: a thin ring around it
    private func ring(isSelected: Bool) -> some View {
        Circle()
            .strokeBorder(.primary.opacity(0.75), lineWidth: 1.5)
            .padding(-3)
            .opacity(isSelected ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// the color well's color: the chosen color, written back as RGB hex text
    private var custom: Binding<Color> {
        Binding(
            get: { color.swiftUIColor },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else {
                    return
                }
                func byte(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
                let hex = String(format: "%02X%02X%02X", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
                color = .custom(hex: hex)
            })
    }
}

/// A slider with its value written beside it, for the glow's duration and opacity.
struct HotCornerGlowSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
                .frame(width: 170)
            Text(verbatim: format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// The lower right half of a disc, cut along the diagonal.
private struct HotCornerHalfDisc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-45), endAngle: .degrees(135), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - The screen

/// A drawing of a display, with a tile in each corner that says what the corner does. A click selects a corner.
struct HotCornersScreen: View {
    let settings: HotCornerSettings
    let selected: HotCorner
    let select: (HotCorner) -> Void
    @Environment(\.colorScheme) private var scheme

    private static let corners: [(HotCorner, Alignment)] = [
        (.topLeft, .topLeading), (.topRight, .topTrailing), (.bottomLeft, .bottomLeading), (.bottomRight, .bottomTrailing),
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            wallpaper
            glow
            menuBar
            dock
            GeometryReader { proxy in
                let tileWidth = min(max(proxy.size.width * 0.34, 130), 210)
                ZStack {
                    ForEach(Self.corners, id: \.0) { corner, alignment in
                        HotCornerTile(
                            corner: corner, setup: settings[corner], isSelected: corner == selected
                        ) {
                            select(corner)
                        }
                        .frame(width: tileWidth)
                        .padding(.horizontal, 10)
                        .padding(.top, corner.isTop ? 28 : 0)
                        .padding(.bottom, corner.isTop ? 0 : 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    }
                }
            }
            .opacity(settings.enabled ? 1 : 0.72)
            .saturation(settings.enabled ? 1 : 0.4)
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .frame(maxWidth: 600)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.14), radius: 8, y: 3)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    private var wallpaper: some View {
        let colors: [Color] =
            scheme == .dark
            ? [Color(red: 0.07, green: 0.09, blue: 0.27), Color(red: 0.27, green: 0.13, blue: 0.42), Color(red: 0.50, green: 0.20, blue: 0.38)]
            : [Color(red: 0.55, green: 0.72, blue: 0.98), Color(red: 0.77, green: 0.62, blue: 0.96), Color(red: 0.98, green: 0.74, blue: 0.70)]
        return ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [.white.opacity(scheme == .dark ? 0.10 : 0.35), .clear], center: UnitPoint(x: 0.7, y: 0.25),
                startRadius: 0, endRadius: 260)
            RadialGradient(
                colors: [colors[1].opacity(0.6), .clear], center: UnitPoint(x: 0.2, y: 0.85), startRadius: 0, endRadius: 220)
        }
    }

    /// The selected corner's glow, at the screen's own corner.
    private var glow: some View {
        GeometryReader { proxy in
            let size = proxy.size.width * 0.85
            let corner = selected
            RadialGradient(
                colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.4), .clear], center: .center,
                startRadius: 0, endRadius: size / 2
            )
            .frame(width: size, height: size)
            .position(
                x: corner.isLeft ? 0 : proxy.size.width, y: corner.isTop ? 0 : proxy.size.height)
        }
        .allowsHitTesting(false)
    }

    private var menuBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "applelogo").font(.system(size: 9, weight: .bold))
                Capsule().frame(width: 26, height: 5)
                Capsule().frame(width: 18, height: 5)
                Capsule().frame(width: 22, height: 5)
                Spacer()
                Capsule().frame(width: 10, height: 5)
                Capsule().frame(width: 10, height: 5)
                Capsule().frame(width: 30, height: 5)
            }
            .foregroundStyle(.primary.opacity(0.5))
            .padding(.horizontal, 12)
            .frame(height: 18)
            .background(.ultraThinMaterial.opacity(0.9))
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5) }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    private var dock: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                ForEach(0..<6, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(.primary.opacity(index == 2 ? 0.45 : 0.28))
                        .frame(width: 14, height: 14)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .padding(.bottom, 6)
        }
        .allowsHitTesting(false)
    }
}

extension HotCorner {
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

/// One corner's tile: what the corner alone does, its delay when it isn't the usual one, and a chip for each modifier
/// that has an action.
struct HotCornerTile: View {
    let corner: HotCorner
    let setup: HotCornerSetup
    let isSelected: Bool
    let onSelect: () -> Void

    private var alignment: HorizontalAlignment { corner.isLeft ? .leading : .trailing }

    private var chips: [(HotCornerModifier, HotCornerAction)] {
        HotCornerModifier.allCases.compactMap { modifier in
            setup[modifier] == .none ? nil : (modifier, setup[modifier])
        }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: alignment, spacing: 5) {
                HStack(spacing: 6) {
                    HotCornerActionIcon(action: setup.plain, size: 13)
                    Text(verbatim: setup.plain.uiTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if setup.delay != 0.15 {
                        Text(verbatim: HotCornerText.delay(setup.delay))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.primary.opacity(0.12), in: Capsule())
                            .fixedSize()
                    }
                }
                .foregroundStyle(setup.plain == .none ? .secondary : .primary)
                .opacity(setup.plain == .none ? 0.7 : 1)
                ForEach(chips, id: \.0) { modifier, action in
                    HStack(spacing: 5) {
                        Text(verbatim: modifier.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(verbatim: action.uiTitle)
                            .font(.system(size: 10))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(.primary.opacity(0.09), in: Capsule())
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: corner.isLeft ? .leading : .trailing)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(corner.title) Corner, \(setup.plain.uiTitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - The pane

/// Settings → Hot Corners, from the settings store and the controller.
struct HotCornersPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        HotCornersSettingsForm(
            preferences: $settings.preferences, isLegacyAppRunning: model.hotCorners.isLegacyAppRunning,
            shortcutNames: model.hotCorners.shortcutNames, onQuitLegacy: { model.hotCorners.quitLegacyApp() },
            onTryGlow: { corner in
                model.hotCorners.showGlowPreview(at: corner, glow: settings.preferences.hotCorners.glow)
            }
        )
        .task {
            model.hotCorners.refreshLegacyAppRunning()
            await model.hotCorners.loadShortcutNames()
        }
    }
}

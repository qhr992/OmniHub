import AppKit

/// Settings › Appearance: the card's background, and which icon the menu
/// bar, the dock ball and the Dock show — the runner, the logo or the
/// status icon, whose three parts are picked here with a live preview.
extension SettingsPane {
    static let cardOpacityKey = "dock.cardOpacity"

    func appearanceSections() -> [NSView] {
        typealias Tint = SettingsSection.Tint
        let config = StatusIcon.Config.current
        return [
            section("Background", "paintbrush.fill", Tint.purple, [
                // Stored as opacity (30–100 %), shown as transparency (0–70 %).
                row(label("Transparency"), PrefSlider(key: Self.cardOpacityKey, fallback: 100, range: 30...100, width: 220,
                                                      suffix: "%", mirror: 100))
            ]),
            section("Menu Bar Icon", "menubar.rectangle", Tint.indigo, [
                row(label("Shows"), PrefChoice(key: StatusIcon.menuBarKey, fallback: 0,
                                               options: [(0, "Buddy"), (1, "Status icon")])),
                ConditionalRow(when: { !StatusIcon.inMenuBar },
                               row(label("Buddy speed"), PrefChoice(key: StatusRunner.speedKey, fallback: StatusRunner.speed,
                                                                    options: [(0, "Follows memory"), (1, "Follows CPU"), (2, "Still")]))),
                PrefCheckbox("Network speed beside the icon", key: StatusRunner.netSpeedKey, fallback: false)
            ]),
            section("Dock Ball", "circle.circle", Tint.blue, [
                row(label("Shows"), PrefChoice(key: StatusIcon.ballKey, fallback: 0,
                                               options: [(0, "Logo"), (1, "Status icon")])),
                row(label("Logo"), button("Choose Image…", #selector(chooseIcon)), button("Default Icon", #selector(resetIcon)))
            ]),
            section("Status Icon", "gauge.with.dots.needle.33percent", Tint.green, [
                StatusIconPreview(),
                row(label("Ring"), PrefChoice(key: StatusIcon.Config.ringKey, fallback: config.ring.rawValue,
                                              options: StatusIcon.Ring.allCases.map { ($0.rawValue, StatusIcon.title($0)) }),
                    label("Middle"), PrefChoice(key: StatusIcon.Config.centerKey, fallback: config.center.rawValue,
                                                options: StatusIcon.Center.allCases.map { ($0.rawValue, StatusIcon.title($0)) }),
                    label("Dots"), PrefChoice(key: StatusIcon.Config.dotsKey, fallback: config.dots.rawValue,
                                              options: StatusIcon.Dots.allCases.map { ($0.rawValue, StatusIcon.title($0)) })),
                row(label("Bottom as"), PrefChoice(key: StatusIcon.bottomStyleKey, fallback: 0,
                                                   options: [(0, "Dots"), (1, "Arc")]),
                    PrefCheckbox("Figure on the ring", key: StatusIcon.ringFigureKey, fallback: true),
                    ConditionalRow(when: { Prefs.bool(StatusIcon.ringFigureKey, true) },
                                   PrefCheckbox("Show the figure while plugged in", key: StatusIcon.figureWhilePluggedKey,
                                                fallback: false))),
                StatusIconColorsRow(),
                PrefCheckbox("Also show in the Dock", key: StatusIcon.dockTileKey, fallback: false)
            ])
        ]
    }
}

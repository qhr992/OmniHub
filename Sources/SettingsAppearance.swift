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
                row(label("Opacity"), PrefSlider(key: Self.cardOpacityKey, fallback: 100, range: 30...100, width: 220,
                                                 suffix: "%")),
                hint("Lower it to see the desktop through the card, blurred. Text and controls stay fully visible.")
            ]),
            section("Menu Bar Icon", "menubar.rectangle", Tint.indigo, [
                row(label("Shows"), PrefChoice(key: StatusIcon.menuBarKey, fallback: 0,
                                               options: [(0, "Runner"), (1, "Status icon")])),
                row(PrefCheckbox("Runner flaps", key: "status.animated", fallback: true),
                    label("faster as"), PrefChoice(key: "status.metric", fallback: 0, options: [(0, "Memory"), (1, "CPU")]),
                    label("fills up"))
            ]),
            section("Dock Ball", "circle.circle", Tint.blue, [
                row(label("Shows"), PrefChoice(key: StatusIcon.ballKey, fallback: 0,
                                               options: [(0, "Logo"), (1, "Status icon")])),
                row(label("Logo"), button("Choose Image…", #selector(chooseIcon)), button("Default Icon", #selector(resetIcon))),
                hint("While music plays the ball shows the cover, whichever is picked.")
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
                    PrefCheckbox("Show the figure while plugged in", key: StatusIcon.figureWhilePluggedKey, fallback: false)),
                StatusIconColorsRow(),
                PrefCheckbox("Also show it in the Dock (a click opens the card)", key: StatusIcon.dockTileKey, fallback: false),
                hint("Laid out like the iPhone “Duo” status icon (after Status Trio). The ring's top shows the figure: the charge on battery, a bolt while charging, a plug when plugged in and not charging or full. The battery's colour follows the charge: green from 80 %, shading through yellow and orange to red at 20 % or less; the bolt and plug are green, the figure turns red at 10 % and yellow in Low Power Mode. An amber dot at the top right means Keep Awake is on.")
            ])
        ]
    }
}

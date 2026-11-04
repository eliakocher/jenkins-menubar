import MenubarCore

/// Where the alert window's butler gets his hat: the season of today's date, or one the caller fixes, which the gallery
/// uses so each of its entries shows one season whatever the date is.
public enum ButlerHatSource: Equatable, Sendable {
    /// the season of today, at the fun level in force
    case today
    /// the given hat, or none
    case fixed(ButlerHat?)

    /// the hat to show now
    @MainActor
    var hat: ButlerHat? {
        switch self {
        case .today: FunModel.currentLevel.flatMap { ButlerSeason.current(on: .now, level: $0)?.hat }
        case .fixed(let hat): hat
        }
    }
}

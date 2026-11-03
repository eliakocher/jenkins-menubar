import MenubarCore
import SwiftUI

/// The Inbox's empty state at Normal and Party (the fun layer): the happy butler wearing the hat of the day, "Inbox Zero",
/// one funny line a day, the butler's tip and a burst of confetti the first time the list is empty on a day. The butler
/// bounces once; at Party a little more. Subtle and the gallery keep the plain empty state.
struct InboxZeroView: View {
    let title: String
    let detail: String
    let level: FunLevel
    let line: String?
    let hat: ButlerHat?
    /// whether the confetti plays now
    let celebrates: Bool

    var body: some View {
        VStack(spacing: 6) {
            let art = AppImages.alert(.happy, hat: hat)
            let size = AppImages.alertSize(of: art, box: 88)
            Image(nsImage: art)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
                .overlay {
                    if AppImages.drawsFallbackHat(.happy, hat: hat), let hat {
                        SeasonalHatOverlay(hat: hat)
                    }
                }
                .funButlerMotion(isHappy: true, level: level)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.title2.weight(.semibold))
                .padding(.top, 6)
            Text(verbatim: detail)
                .foregroundStyle(.secondary)
            if let line {
                Text(verbatim: line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                    .padding(.top, 6)
            }
            FunTipCaption()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if celebrates {
                ConfettiBurst(level: level, origin: UnitPoint(x: 0.5, y: 0.4), seed: 11)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where the Inbox's empty state picks between the plain one and ``InboxZeroView``: it reads the model for the level, the day's
/// line and whether the confetti is due.
struct InboxEmptyState: View {
    let empty: InboxListModel.Empty
    @Environment(AppModel.self) private var model: AppModel?
    @ViewState private var celebrates = false

    var body: some View {
        if let model, empty.title == InboxListModel.zeroTitle, let level = model.fun.level, level.showsMoments {
            InboxZeroView(
                title: empty.title, detail: empty.detail, level: level, line: model.fun.inboxZeroLine(at: .now),
                hat: model.pipelines.butlerHat, celebrates: celebrates)
                .task {
                    celebrates = model.fun.inboxZeroReached(at: .now)
                }
        } else {
            ContentUnavailableView {
                Label(empty.title, systemImage: empty.symbol)
            } description: {
                Text(verbatim: empty.detail)
            }
        }
    }
}

import SwiftUI

/// A short row of words with one of them chosen: timeline or projects and
/// day, week, month or all in the bar at the top of the board, and the kind
/// of mini map in the settings.
///
/// Plain, not glass: a small solid tab. A word can have a small symbol
/// before it.
struct SegmentedPill<Value: Hashable>: View {

    let options: [Value]
    let selection: Value
    var title: (Value) -> String
    /// The name of a system symbol to go before a word, if it has one.
    var symbol: (Value) -> String? = { _ in nil }
    /// A size up, for the bar at the top of the board.
    var large = false
    var onSelect: (Value) -> Void

    var body: some View {
        let size: CGFloat = large ? 11 : 10
        HStack(spacing: 1) {
            ForEach(options, id: \.self) { option in
                let chosen = selection == option
                Button {
                    onSelect(option)
                } label: {
                    HStack(spacing: large ? 6 : 5) {
                        if let symbol = symbol(option) {
                            // Kept light and a touch smaller than the word: it
                            // is a hint, not a second label.
                            Image(systemName: symbol)
                                .font(.system(size: size - 0.5, weight: chosen ? .medium : .regular))
                                .accessibilityHidden(true)
                        }
                        Text(title(option))
                            .font(Theme.mono(size, weight: chosen ? .medium : .regular))
                    }
                    .foregroundStyle(chosen ? Theme.text : Theme.textMuted)
                    .padding(.horizontal, large ? 11 : 9)
                    .frame(height: large ? 23 : 20)
                    .background(
                        chosen ? Theme.selected : Color.clear,
                        in: RoundedRectangle(cornerRadius: large ? 8 : 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .fixedSize()
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: large ? 10 : 9))
        .overlay {
            RoundedRectangle(cornerRadius: large ? 10 : 9)
                .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth)
        }
    }
}

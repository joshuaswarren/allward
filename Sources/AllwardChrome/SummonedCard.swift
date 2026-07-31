import SwiftUI

/// Frames a summoned surface so it always reads as a card inside the window.
///
/// Each surface already chooses its own width, so the card is sized to that
/// ideal rather than stretched to whatever space the scrim offers. Height is
/// the axis that ran past the window and clipped, which looks like a broken
/// window rather than a designed card, so height alone is capped: a card that
/// fits keeps its natural size and sits centred, one that does not fit scrolls.
struct SummonedCard<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content

    private var card: some View {
        content.fixedSize(horizontal: true, vertical: false)
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            card
            ScrollView(.vertical) { card }
                .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: maxHeight > 0 ? maxHeight : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

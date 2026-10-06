import SwiftUI

#if os(iOS)
extension View {
    /// Lets a pull down uncover `field`, a row `height` tall at the top of the list, as it would a
    /// navigation bar's search field: if `startHidden`, the list opens scrolled just past it. Scrolling
    /// never comes to rest with it partly shown; `next` is the row below it, which takes the top when it
    /// is hidden. A list too short to scroll it away keeps it shown. `tucked` follows how much of it is
    /// out of view, from 0 to 1. Does nothing before iOS 18.
    @ViewBuilder func pullToReveal(_ field: some Hashable, next: some Hashable, height: CGFloat, startHidden: Bool, tucked: Binding<CGFloat>) -> some View {
        if #available(iOS 18.0, *) {
            modifier(PullToReveal(field: field, next: next, height: height, startHidden: startHidden, fraction: tucked))
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
struct PullToReveal<ID: Hashable, Next: Hashable>: ViewModifier {
    let field: ID
    let next: Next
    let height: CGFloat
    let startHidden: Bool
    @Binding var fraction: CGFloat
    /// How far the field is scrolled out of view, from 0 (fully shown) to `height` (fully hidden).
    @State private var tucked: CGFloat = 0
    /// Whether the field was last moving into view, so a short pull is enough to finish revealing it.
    @State private var opening = false
    /// How far the content can scroll, once laid out; lists shorter than the field just keep it in view.
    @State private var room: CGFloat?
    @State private var placed = false

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    min(max(0, geometry.contentOffset.y + geometry.contentInsets.top), height)
                } action: { old, new in
                    opening = new < old
                    tucked = new
                    fraction = height > 0 ? new / height : 0
                }
                .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                    guard geometry.contentSize.height > 0 else { return nil }
                    return geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                } action: { _, new in
                    room = new
                }
                .onScrollPhaseChange { _, phase in
                    guard phase == .idle, tucked > 0.5, tucked < height - 0.5 else { return }
                    let reveal = (room ?? 0) < height || tucked < height * (opening ? 0.75 : 0.25)
                    withAnimation(.snappy(duration: 0.25)) {
                        if reveal { proxy.scrollTo(field, anchor: .top) } else { proxy.scrollTo(next, anchor: .top) }
                    }
                }
                .onChange(of: height > 0 && room != nil, initial: true) { _, measured in
                    guard measured, let room, !placed else { return }
                    placed = true
                    if startHidden && room >= height { proxy.scrollTo(next, anchor: .top) }
                }
        }
    }
}

/// Fades `content` out as `hidden` goes from 0 to 1. It reads the binding itself, so only this view
/// updates while it changes.
struct Fading<Content: View>: View {
    @Binding var hidden: CGFloat
    @ViewBuilder let content: Content
    var body: some View { content.opacity(1 - hidden) }
}
#endif

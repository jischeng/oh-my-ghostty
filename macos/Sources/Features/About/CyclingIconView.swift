import SwiftUI

/// The branded icon displayed by the OMG About window.
struct CyclingIconView: View {
    var body: some View {
        ghosttyIconImage()
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 128)
            .accessibilityLabel("OMG Application Icon")
    }
}

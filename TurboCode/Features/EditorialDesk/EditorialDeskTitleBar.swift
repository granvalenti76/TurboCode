import SwiftUI

/// Stable title chrome for the desk. Layout controls are intentionally absent
/// until they have a real presentation action behind them.
struct EditorialDeskTitleBar: View {
    var body: some View {
        Text("Editorial Desk")
            .font(.system(size: 14, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(.bar)
            .accessibilityAddTraits(.isHeader)
    }
}

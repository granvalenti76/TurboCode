import Testing
@testable import TurboCode

@Suite("Sidebar backdrop preference")
struct SidebarBackdropPreferenceTests {
    @Test("A missing value keeps the translucent sidebar")
    func missingValueKeepsTranslucentSidebar() {
        #expect(SidebarBackdropPreference(storedValue: nil) == .translucent)
    }

    @Test("An unknown value falls back to the translucent sidebar")
    func unknownValueFallsBackToTranslucentSidebar() {
        #expect(SidebarBackdropPreference(storedValue: "glass") == .translucent)
    }

    @Test("Every case survives a round trip through its stored value")
    func everyCaseRoundTrips() {
        for preference in SidebarBackdropPreference.allCases {
            #expect(SidebarBackdropPreference(storedValue: preference.rawValue) == preference)
        }
    }
}

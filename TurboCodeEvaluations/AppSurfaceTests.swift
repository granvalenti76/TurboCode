import Testing
@testable import TurboCode

@Suite("App surface tokens")
struct AppSurfaceTests {
    @Test("Every surface has distinct light and dark values")
    func everySurfaceHasDistinctLightAndDarkValues() {
        for token in AppSurface.allTokens {
            #expect(token.light != token.dark, "\(token.name)")
            #expect(AppSurface.luminance(hex: token.light) > AppSurface.luminance(hex: token.dark), "\(token.name)")
        }
    }

    @Test("The sidebar is darker than the canvas and the canvas darker than a card")
    func surfacesKeepTheirLuminanceOrder() {
        let luminance = AppSurface.luminance(hex:)
        #expect(luminance(AppSurface.sidebarToken.light) < luminance(AppSurface.canvasToken.light))
        #expect(luminance(AppSurface.canvasToken.light) < luminance(AppSurface.cardToken.light))
        #expect(luminance(AppSurface.sidebarToken.dark) < luminance(AppSurface.canvasToken.dark))
        #expect(luminance(AppSurface.canvasToken.dark) < luminance(AppSurface.cardToken.dark))
    }

    @Test("Surface names are unique so dynamic colors do not collide")
    func surfaceNamesAreUnique() {
        let names = AppSurface.allTokens.map(\.name)
        #expect(Set(names).count == names.count)
    }
}

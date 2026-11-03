import MenubarCore
import Testing

@testable import MenubarUI

/// The user's own hat pictures win over the older art and the drawn hats (the fun layer): the order of the file names decides.
@Suite("AppImages")
struct AppImagesTests {
    @Test("FUN-11 the alert's butler takes the user's hat picture first, then the older one; the peek's has a file only for three hats")
    func hatArtNames() {
        #expect(AppImages.alertArtNames(.happy, hat: .witch) == ["happy-witch", "happy-halloween"])
        #expect(AppImages.alertArtNames(.sad, hat: .newYear) == ["sad-newyear", "sad-party"])
        #expect(AppImages.alertArtNames(.happy, hat: .newYear) == ["happy-newyear", "happy-party"])
        #expect(AppImages.alertArtNames(.sad, hat: .santa) == ["sad-santa"])
        #expect(AppImages.peekHatArtName(.party) == "peek-side-party" && AppImages.peekHatArtName(.newYear) == "peek-side-party")
        #expect(AppImages.peekHatArtName(.santa) == "peek-side-santa" && AppImages.peekHatArtName(.witch) == "peek-side-witch")
        #expect(AppImages.peekHatArtName(.carnival) == nil && AppImages.peekHatArtName(.easter) == nil)
    }
}

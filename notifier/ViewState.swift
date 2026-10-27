import SwiftUI

/// SwiftUI's State property wrapper, for the views' `@ViewState`. Since the macOS 27 SDK, `@State` is SwiftUI's State
/// macro, whose plugin only Xcode has, so with only the Command Line Tools no view compiles; a typealias named State
/// does not help, the macro wins. Under another name, the attribute can only be the property wrapper, which every SDK
/// has. build.sh refuses `@State`, so it does not come back with a view built in Xcode.
typealias ViewState = SwiftUI.State

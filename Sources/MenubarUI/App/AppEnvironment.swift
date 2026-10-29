import MenubarCore
import SwiftUI

extension View {
    /// Puts the app's model, its stores and the router into the environment, where the views read them with
    /// `@Environment(PipelinesStore.self)` and the like. `@AppStorage` values go into the preferences' suite.
    ///
    /// The app applies it to every scene: the menubar item's content and label, the main window and Settings.
    ///
    /// - Parameters:
    ///   - model: the app's model
    ///   - router: the app's one router
    /// - Returns: the view with its environment
    public func appEnvironment(_ model: AppModel, router: WindowRouter) -> some View {
        environment(model)
            .environment(model.pipelines)
            .environment(model.projects)
            .environment(model.mergeRequests)
            .environment(model.workItems)
            .environment(model.settings)
            .environment(model.activity)
            .environment(model.updates)
            .environment(router)
            .defaultAppStorage(model.dependencies.preferences)
    }
}

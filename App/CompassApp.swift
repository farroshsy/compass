import CompassInfrastructure
import CompassUI
import SwiftUI

/// The shell. It constructs the composed store and hands it to the scene, and it
/// deliberately does nothing else.
///
/// **Nothing in this folder is compiled by `swift test`, and there is no test
/// target for it.** That was proved to matter: a verification pass restored a
/// `preconditionFailure` on the store-open failure path and deleted the argument
/// that hands the journal its already-known high-water mark, and all 111 tests
/// still passed. Both lines were fixes for real bugs.
///
/// So every line that can be wrong lives in
/// ``CompassInfrastructure/AppComposition``, which the test suite compiles, and
/// this file holds no branch, no `catch`, and no forwarded argument — because an
/// argument here is an argument no test can see.
@main
struct CompassApp: App {

    @State private var model = TodayModel(AppComposition.compose())

    /// The one line week 4 adds to this folder.
    ///
    /// `BGTaskScheduler.register` must run **before the app finishes
    /// launching** — a constraint of the framework, not a decision this file
    /// gets to make — so it is the rare thing that genuinely cannot live
    /// anywhere else. It still holds no branch and no argument:
    /// ``CompassInfrastructure/AnchorScheduler`` is where every line that can be
    /// wrong lives, and `swift test` compiles that.
    init() {
        AnchorScheduler.register()
    }

    var body: some Scene {
        WindowGroup {
            TodayView(model: model)
        }
    }
}

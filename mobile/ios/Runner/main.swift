import BuzzPadApp
import UIKit

// One binary, two apps: iPad runs the native SwiftUI client (ipad/), and
// iPhone runs the Flutter app. Info.plist's `~ipad` keys give the iPad side
// its own scene manifest and orientations.
MainActor.assumeIsolated {
  if UIDevice.current.userInterfaceIdiom == .pad {
    BuzzPad.run()
  }
}
UIApplicationMain(
  CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))

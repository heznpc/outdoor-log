import SwiftUI
import WatchKit

@main
struct OutdoorLogWatchApp: App {
  @WKApplicationDelegateAdaptor private var appDelegate: OutdoorLogWatchDelegate
  @StateObject private var controller = WatchWorkoutController.shared
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      WatchRootView(controller: controller)
        .task { await controller.activate() }
        .onChange(of: scenePhase) { _, phase in
          if phase == .active { Task { await controller.activate() } }
        }
    }
  }
}

final class OutdoorLogWatchDelegate: NSObject, WKApplicationDelegate {
  func applicationDidFinishLaunching() {
    Task { @MainActor in await WatchWorkoutController.shared.activate() }
  }

  func handleActiveWorkoutRecovery() {
    Task { @MainActor in await WatchWorkoutController.shared.recoverFromSystem() }
  }
}

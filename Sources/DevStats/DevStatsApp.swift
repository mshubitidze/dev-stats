import SwiftUI

@main
struct DevStatsApp: App {
  @State private var model = StatsModel()

  var body: some Scene {
    MenuBarExtra {
      StatsPanel(model: model)
    } label: {
      MenuBarLabel(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}

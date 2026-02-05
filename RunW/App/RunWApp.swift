import SwiftUI

@main
struct RunWApp: App {
    @StateObject private var appManager = AppManager()
    @StateObject private var proxyManager = ProxyManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appManager)
                .environmentObject(proxyManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appManager)
                .environmentObject(proxyManager)
        } label: {
            Image(systemName: proxyManager.isEnabled ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
        }
    }
}

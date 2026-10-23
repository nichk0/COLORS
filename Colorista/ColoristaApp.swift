import SwiftUI

@main
struct ColoristaApp: App {
    /// Solo per gli orientamenti (la modalità desktop gira il telefono in orizzontale).
    @UIApplicationDelegateAdaptor(DelegatoOrientamento.self) private var delegato

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Dice a iOS che l'app sta anche in orizzontale. Non tocca le scene (un delegato che le configura rompeva l'avvio).
final class DelegatoOrientamento: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        .allButUpsideDown
    }
}

import SwiftUI

@main
struct ElectricPipaApp: App {
    @StateObject private var audio = AudioEngine()

    var body: some Scene {
        WindowGroup {
            PipaView()
                .environmentObject(audio)
                .preferredColorScheme(.light)
        }
    }
}

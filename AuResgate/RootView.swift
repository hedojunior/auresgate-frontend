import SwiftUI

struct RootView: View {
    @StateObject private var petStore = PetStore()

    var body: some View {
        TabView {
            SearchHomeView()
                .tabItem {
                    Label("Busca", systemImage: "dot.radiowaves.left.and.right")
                }

            MyPetsView()
                .tabItem {
                    Label("Meus pets", systemImage: "pawprint.fill")
                }
        }
        .environmentObject(petStore)
        .tint(Theme.brand)
    }
}

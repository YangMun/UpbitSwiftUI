import SwiftUI

struct ContentView: View {
    @State private var isLoggedIn = false
    
    var body: some View {
        GeometryReader { geometry in
            if isLoggedIn {
                MainPage()
            } else {
                LoginPage(isLoggedIn: $isLoggedIn)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

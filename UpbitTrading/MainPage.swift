import SwiftUI

struct MainPage: View {
    @State private var selectedTab = 0
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                TabView(selection: $selectedTab) {
                    DashboardView()
                        .tabItem {
                            Image(systemName: "chart.bar")
                            Text("Dashboard")
                        }
                        .tag(0)
                    
                    TradeTabView()
                        .tabItem {
                            Image(systemName: "arrow.left.arrow.right")
                            Text("Trade")
                        }
                        .tag(1)
                    
                    SettingsView()
                        .tabItem {
                            Image(systemName: "gear")
                            Text("Settings")
                        }
                        .tag(2)
                    
                    FetchStocksView()
                        .tabItem {
                            Image(systemName: "list.bullet")
                            Text("종목 가져오기")
                        }
                        .tag(3)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

struct MainPage_Previews: PreviewProvider {
    static var previews: some View {
        MainPage()
    }
}

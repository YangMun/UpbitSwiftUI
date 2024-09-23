import SwiftUI
import Charts
import AppKit

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()
    @State private var selectedMarket: Market?

    var body: some View {
        HSplitView {
            // 왼쪽: 시장 목록
            List(viewModel.markets, selection: $selectedMarket) { market in
                Text(market.koreanName)
                    .tag(market)
            }
            .frame(minWidth: 200)
            
            // 오른쪽: 선택된 시장의 대시보드
            VStack {
                if let market = selectedMarket {
                    marketDetailView(for: market)
                } else {
                    Text("시장을 선택하세요")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400)
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear(perform: viewModel.loadMarkets)
        .onChange(of: selectedMarket) { newMarket in
            if let market = newMarket {
                viewModel.loadMarketPrices(for: market)
            }
        }
    }

    private func marketDetailView(for market: Market) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(market.koreanName)
                .font(.title)
            
            HStack {
                statItem(title: "현재가", value: viewModel.currentPrice(for: market))
                Spacer()
                statItem(title: "변동률", value: viewModel.priceChange(for: market))
                    .foregroundColor(viewModel.priceChangeColor(for: market))
            }
            
            Text("최근 1주일 가격 추이")
                .font(.headline)
            
            if viewModel.isLoadingPrices(for: market.id) {
                ProgressView()
                    .frame(height: 200)
            } else if viewModel.hasPricesLoaded(for: market.id) {
                Chart {
                    ForEach(viewModel.chartData(for: market), id: \.date) { item in
                        LineMark(
                            x: .value("Date", item.date),
                            y: .value("Price", item.price)
                        )
                    }
                }
                .frame(height: 200)
            } else {
                Text("데이터를 불러오는 중 오류가 발생했습니다.")
                    .frame(height: 200)
            }
            
            Spacer()
        }
        .padding()
    }

    private func statItem(title: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
        }
    }
}

class DashboardViewModel: ObservableObject {
    @Published var markets: [Market] = []
    @Published var marketPrices: [String: [MarketPrice]] = [:]
    @Published var loadingStates: [String: Bool] = [:]

    func loadMarkets() {
        Task {
            do {
                let fetchedMarkets = try await DatabaseManager.shared.fetchMarkets()
                DispatchQueue.main.async {
                    self.markets = fetchedMarkets
                }
            } catch {
                print("Error loading markets: \(error)")
            }
        }
    }

    func loadMarketPrices(for market: Market) {
        guard marketPrices[market.id] == nil else { return }
        
        DispatchQueue.main.async {
            self.loadingStates[market.id] = true
        }
        
        Task {
            do {
                let prices = try await DatabaseManager.shared.DashBoardMarketPrices(for: market.id)
                DispatchQueue.main.async {
                    self.marketPrices[market.id] = prices
                    self.loadingStates[market.id] = false
                }
            } catch {
                print("Error loading prices for \(market.id): \(error)")
                DispatchQueue.main.async {
                    self.loadingStates[market.id] = false
                }
            }
        }
    }

    func isLoadingPrices(for marketId: String) -> Bool {
        return loadingStates[marketId] ?? false
    }

    func hasPricesLoaded(for marketId: String) -> Bool {
        return marketPrices[marketId] != nil
    }

    func currentPrice(for market: Market) -> String {
        guard let latestPrice = marketPrices[market.id]?.last?.tradePrice else {
            return "N/A"
        }
        return String(format: "%.2f", latestPrice)
    }

    func priceChange(for market: Market) -> String {
        guard let prices = marketPrices[market.id], prices.count >= 2 else {
            return "N/A"
        }
        let change = prices.last!.tradePrice - prices.first!.tradePrice
        let percentage = (change / prices.first!.tradePrice) * 100
        return String(format: "%.2f%%", percentage)
    }

    func priceChangeColor(for market: Market) -> Color {
        guard let prices = marketPrices[market.id], prices.count >= 2 else {
            return .primary
        }
        let change = prices.last!.tradePrice - prices.first!.tradePrice
        return change >= 0 ? .green : .red
    }

    func chartData(for market: Market) -> [(date: Date, price: Double)] {
        guard let prices = marketPrices[market.id] else {
            return []
        }
        return prices.map { (date: $0.timestamp, price: $0.tradePrice) }
    }
}

struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        DashboardView()
    }
}

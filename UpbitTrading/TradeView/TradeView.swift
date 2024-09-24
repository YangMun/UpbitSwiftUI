import SwiftUI
import Combine

struct TradeTabView: View {
    @StateObject private var tradeManager = TradeManager()
    @State private var logs: [String] = []

    var body: some View {
        HSplitView {
            // 좌측: 버튼 영역
            VStack {
                Button(action: {
                    Task {
                        await tradeManager.toggleTrading()
                        await MainActor.run {
                            addLog(tradeManager.isTrading ? "자동 매매 시작" : "자동 매매 종료")
                        }
                    }
                }) {
                    Text(tradeManager.isTrading ? "Turn Off" : "Turn On")
                        .frame(minWidth: 100)
                        .padding()
                        .background(tradeManager.isTrading ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()
                
                Spacer()
            }
            .frame(minWidth: 150)
            
            // 우측: 로그 영역
            VStack {
                Text("거래 로그")
                    .font(.headline)
                    .padding()
                
                List(logs, id: \.self) { log in
                    Text(log)
                }
            }
            .frame(minWidth: 300)
        }
        .onReceive(tradeManager.$latestLog) { log in
            addLog(log)
        }
    }
    
    @MainActor
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
    }
}

import Foundation
import Combine

class TradeManager: ObservableObject {
    @MainActor @Published var isTrading = false
    @MainActor @Published var latestLog = ""
    
    private var tradingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    @MainActor
    func toggleTrading() async {
        isTrading.toggle()
        if isTrading {
            await startTrading()
        } else {
            await stopTrading()
        }
    }
    
    @MainActor
    private func startTrading() async {
        tradingTask = Task {
            let startTime = Date()
            let tradingDuration: TimeInterval = 6.5 * 60 * 60 // 6시간 30분

            while await self.isTrading && Date().timeIntervalSince(startTime) < tradingDuration {
                await performTradingCycle()
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1초 대기
            }

            if await self.isTrading {
                await MainActor.run {
                    self.isTrading = false
                    self.latestLog = "6시간 30분 거래 기간이 종료되었습니다."
                }
                await sellAllHoldings()
            }
        }
    }
    
    @MainActor
    private func stopTrading() async {
        tradingTask?.cancel()
        await sellAllHoldings()
    }
    
    private func performTradingCycle() async {
        do {
            let markets = try await DatabaseManager.shared.fetchMarkets()
            for market in markets {
                let prices = try await DatabaseManager.shared.DashBoardMarketPrices(for: market.id)
                if let tradingSignal = analyzePrices(prices) {
                    await executeTrade(market: market, signal: tradingSignal)
                }
            }
        } catch {
            await MainActor.run {
                self.latestLog = "Error in trading cycle: \(error.localizedDescription)"
            }
        }
    }
    
    private func analyzePrices(_ prices: [MarketPrice]) -> TradingSignal? {
        guard prices.count >= 20 else { return nil }  // 최소 20개의 데이터 포인트 필요

        let closePrices = prices.map { $0.tradePrice }
        let volumes = prices.map { $0.candleAccTradeVolume }

        let ema9 = calculateEMA(prices: closePrices, period: 9)
        let ema20 = calculateEMA(prices: closePrices, period: 20)
        let rsi = calculateRSI(prices: closePrices, period: 14)

        let currentPrice = closePrices.last!
        let currentVolume = volumes.last!
        let averageVolume = volumes.suffix(5).reduce(0, +) / 5

        // 매수 신호
        if currentPrice > ema9 && ema9 > ema20 &&  // 단기 상승 추세
           rsi > 50 && rsi < 70 &&                 // RSI가 상승 구간이지만 과매수는 아님
           currentVolume > averageVolume * 1.2 {   // 거래량 약간 증가
            return .buy
        }

        // 매도 신호
        if currentPrice < ema9 && ema9 < ema20 &&  // 단기 하락 추세
           rsi < 50 && rsi > 30 &&                 // RSI가 하락 구간이지만 과매도는 아님
           currentVolume > averageVolume * 1.2 {   // 거래량 약간 증가
            return .sell
        }

        return nil
    }
    
    private func calculateEMA(prices: [Double], period: Int) -> Double {
        guard prices.count >= period else { return 0 }
        let k = 2.0 / Double(period + 1)
        var ema = prices[0]
        for i in 1..<prices.count {
            ema = (prices[i] * k) + (ema * (1 - k))
        }
        return ema
    }

    private func calculateRSI(prices: [Double], period: Int) -> Double {
        guard prices.count > period else { return 0 }
        var gains = [Double]()
        var losses = [Double]()

        for i in 1..<prices.count {
            let difference = prices[i] - prices[i-1]
            if difference >= 0 {
                gains.append(difference)
                losses.append(0)
            } else {
                gains.append(0)
                losses.append(-difference)
            }
        }

        let averageGain = gains.suffix(period).reduce(0, +) / Double(period)
        let averageLoss = losses.suffix(period).reduce(0, +) / Double(period)

        if averageLoss == 0 { return 100 }
        let rs = averageGain / averageLoss
        return 100 - (100 / (1 + rs))
    }
    
    private func executeTrade(market: Market, signal: TradingSignal) async {
        do {
            let ticker = try await fetchCurrentPrice(market: market)
            let balance = try await fetchKRWBalance()
            
            switch signal {
            case .buy:
                // 매수 로직
                let buyPrice = calculateBuyPrice(currentPrice: ticker.tradePrice)
                let orderAmount = min(balance * 0.1, 100000)  // 최대 10만원으로 제한
                let quantity = orderAmount / buyPrice
                
                let buyOrder = UpbitOrder(market: market.id, side: "bid", volume: String(quantity), price: String(buyPrice), ordType: "limit")
                let orderResult = try await UpbitAPI.shared.placeOrder(order: buyOrder)
                
                await MainActor.run {
                    self.latestLog = "매수 주문 실행: \(market.koreanName) (\(market.id)) - 주문번호: \(orderResult.uuid), 가격: \(buyPrice)"
                }
                
            case .sell:
                // 매도 로직
                let sellPrice = calculateSellPrice(currentPrice: ticker.tradePrice)
                let holding = try await fetchHolding(market: market)
                
                if holding > 0 {
                    let sellOrder = UpbitOrder(market: market.id, side: "ask", volume: String(holding), price: String(sellPrice), ordType: "limit")
                    let orderResult = try await UpbitAPI.shared.placeOrder(order: sellOrder)
                    
                    await MainActor.run {
                        self.latestLog = "매도 주문 실행: \(market.koreanName) (\(market.id)) - 주문번호: \(orderResult.uuid), 가격: \(sellPrice)"
                    }
                } else {
                    await MainActor.run {
                        self.latestLog = "매도 신호 감지: \(market.koreanName) (\(market.id)) - 보유 수량 없음"
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.latestLog = "거래 실행 오류: \(error.localizedDescription)"
            }
        }
    }

    private func calculateBuyPrice(currentPrice: Double) -> Double {
        // 현재 가격보다 약간 낮은 가격에 매수 주문
        // 예: 현재 가격의 99.9%
        return currentPrice * 0.999
    }

    private func calculateSellPrice(currentPrice: Double) -> Double {
        // 현재 가격보다 약간 높은 가격에 매도 주문
        // 예: 현재 가격의 100.1%
        return currentPrice * 1.001
    }

    private func fetchCurrentPrice(market: Market) async throws -> UpbitTicker {
        return try await UpbitAPI.shared.fetchTicker(market: market.id)
    }

    private func fetchKRWBalance() async throws -> Double {
        let accounts = try await UpbitAPI.shared.fetchAccounts()
        guard let krwAccount = accounts.first(where: { $0.currency == "KRW" }) else {
            throw TradeError.insufficientBalance
        }
        return krwAccount.balance
    }

    private func fetchHolding(market: Market) async throws -> Double {
        let accounts = try await UpbitAPI.shared.fetchAccounts()
        guard let account = accounts.first(where: { $0.currency == market.id.replacingOccurrences(of: "KRW-", with: "") }) else {
            return 0
        }
        return account.balance
    }
    
    @MainActor 
    private func sellAllHoldings() {
          // 실제 모든 보유 종목 매도 로직을 여기에 구현합니다.
          latestLog = "모든 보유 종목 매도 실행"
      }
}

enum TradingSignal {
    case buy
    case sell
}

struct UpbitOrder: Codable {
    let market: String
    let side: String
    let volume: String
    let price: String
    let ordType: String
}

struct OrderResult: Codable {
    let uuid: String
    let side: String
    let ordType: String
    let price: String
    let avgPrice: String
    let state: String
    let market: String
    let createdAt: String
    let volume: String
    let remainingVolume: String
    let reservedFee: String
    let remainingFee: String
    let paidFee: String
    let locked: String
    let executedVolume: String
    let tradeCount: Int
}

struct UpbitTicker: Codable {
    let market: String
    let tradePrice: Double
    // ... 기타 필요한 필드
}

enum TradeError: Error {
    case insufficientBalance
    case invalidMarketPrice
    case orderFailed
}

struct TradeTabView_Previews: PreviewProvider {
    static var previews: some View {
        TradeTabView()
    }
}

import SwiftUI
import Combine

struct TradeTabView: View {
    @StateObject private var tradeManager = TradeManager()
    @State private var logs: [String] = []
    @State private var balance: Double = 0.0
    
    let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

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
                
                Text("현재 잔고: \(balance, specifier: "%.2f") KRW")
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
        .onReceive(timer) { _ in
            Task {
                await updateBalance()
            }
        }
        .onAppear {
            Task {
                await updateBalance()
            }
        }
    }
    
    @MainActor
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
    }
    
    private func updateBalance() async {
        do {
            let newBalance = try await tradeManager.fetchKRWBalance()
            await MainActor.run {
                self.balance = newBalance
            }
        } catch {
            print("Error updating balance: \(error)")
        }
    }
}

class TradeManager: ObservableObject {
     @MainActor @Published var isTrading = false
     @MainActor @Published var latestLog = ""
     
     private var tradingTask: Task<Void, Never>?
     private var cancellables = Set<AnyCancellable>()
     
     // Upbit 거래 수수료 (0.05%)
     private let fee = 0.0005
     
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
                 try? await Task.sleep(nanoseconds: 30_000_000_000) // 30초 대기
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
        guard prices.count >= 10 else { return nil }  // 최소 10개의 데이터 포인트 필요

        let closePrices = prices.map { $0.tradePrice }
        let volumes = prices.map { $0.candleAccTradeVolume }

        // 단기 EMA 사용 (5분)
        let ema5 = calculateEMA(prices: closePrices, period: 5)
        let ema10 = calculateEMA(prices: closePrices, period: 10)

        // 단기 RSI 사용 (9분)
        let rsi = calculateRSI(prices: closePrices, period: 9)

        let currentPrice = closePrices.last!
        let currentVolume = volumes.last!
        let averageVolume = volumes.suffix(5).reduce(0, +) / 5

        // 매수 신호
        if currentPrice > ema5 && ema5 > ema10 &&  // 단기 상승 추세
           rsi > 50 && rsi < 70 &&                 // RSI가 상승 구간이지만 과매수는 아님
           currentVolume > averageVolume * 1.5 {   // 거래량 증가
            return .buy
        }

        // 매도 신호
        if currentPrice < ema5 && ema5 < ema10 &&  // 단기 하락 추세
           (rsi < 30 || rsi > 70) &&               // RSI가 과매도 또는 과매수 구간
           currentVolume > averageVolume * 1.5 {   // 거래량 증가
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
                let orderAmount = balance * 0.99 //잔고의 99%를 사용 (1%는 수수료 및 기타 비용을 위해 예비)
                let quantity = (orderAmount / buyPrice) * (1 - fee)  // 수수료를 고려한 수량 계산
                
                let buyOrder = UpbitOrder(market: market.id, side: "bid", volume: String(quantity), price: String(buyPrice), ordType: "limit")
                let orderResult = try await UpbitAPI.shared.placeOrder(order: buyOrder)
                
                await MainActor.run {
                    self.latestLog = "매수 주문 실행: \(market.koreanName) (\(market.id)) - 주문번호: \(orderResult.uuid), 가격: \(buyPrice), 수량: \(quantity)"
                }
                
            case .sell:
                // 매도 로직
                let sellPrice = calculateSellPrice(currentPrice: ticker.tradePrice)
                let holding = try await fetchHolding(market: market)
                
                if holding > 0 {
                    let sellQuantity = holding * (1 - fee)  // 수수료를 고려한 매도 수량
                    let sellOrder = UpbitOrder(market: market.id, side: "ask", volume: String(sellQuantity), price: String(sellPrice), ordType: "limit")
                    let orderResult = try await UpbitAPI.shared.placeOrder(order: sellOrder)
                    
                    await MainActor.run {
                        self.latestLog = "매도 주문 실행: \(market.koreanName) (\(market.id)) - 주문번호: \(orderResult.uuid), 가격: \(sellPrice), 수량: \(sellQuantity)"
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

    public func fetchKRWBalance() async throws -> Double {
        let accounts = try await UpbitAPI.shared.fetchAccounts()
        guard let krwAccount = accounts.first(where: { $0.currency == "KRW" }) else {
            throw TradeError.insufficientBalance
        }
        return Double(krwAccount.balance) ?? 0
    }

    private func fetchHolding(market: Market) async throws -> Double {
        let accounts = try await UpbitAPI.shared.fetchAccounts()
        guard let account = accounts.first(where: { $0.currency == market.id.replacingOccurrences(of: "KRW-", with: "") }) else {
            return 0
        }
        return Double(account.balance) ?? 0
    }
    
    @MainActor
    private func sellAllHoldings() async {
        do {
            let accounts = try await UpbitAPI.shared.fetchAccounts()
            let nonKRWAccounts = accounts.filter { account in
                account.currency != "KRW" &&
                account.currency != "VTHO" && // VTHO 제외
                (Double(account.balance) ?? 0) > 0
            }
            
            if nonKRWAccounts.isEmpty {
                self.latestLog = "매도 가능한 보유 종목이 없습니다"
                return
            }
            
            for account in nonKRWAccounts {
                let market = "KRW-\(account.currency)"
                let order = UpbitOrder(
                    market: market,
                    side: "ask",
                    volume: account.balance,
                    price: nil,  // 시장가 주문이므로 가격을 지정하지 않습니다.
                    ordType: "market"
                )
                
                do {
                    let result = try await UpbitAPI.shared.placeOrder(order: order)
                    self.latestLog = "매도 주문 실행: \(market) - 주문번호: \(result.uuid), 수량: \(account.balance)"
                } catch {
                    self.latestLog = "매도 주문 실패: \(market) - 오류: \(error.localizedDescription)"
                }
                
                // API 호출 사이에 잠시 대기
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5초 대기
            }
            
            if !nonKRWAccounts.isEmpty {
                self.latestLog = "매도 가능한 모든 보유 종목 매도 완료"
            }

            // VTHO 보유 여부 확인 및 로그 추가
            if let vthoAccount = accounts.first(where: { $0.currency == "VTHO" }),
               (Double(vthoAccount.balance) ?? 0) > 0 {
                self.latestLog += "\nVTHO는 상장폐지되어 매도하지 않았습니다. 보유 수량: \(vthoAccount.balance)"
            }
        } catch {
            self.latestLog = "보유 종목 조회 실패: \(error.localizedDescription)"
            print("보유 종목 조회 실패: \(error.localizedDescription)")
        }
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
    let price: String?
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

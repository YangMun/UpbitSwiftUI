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
                    tradeManager.toggleTrading()
                    addLog(tradeManager.isTrading ? "자동 매매 시작" : "자동 매매 종료")
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
    
    private func addLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
    }
}

class TradeManager: ObservableObject {
    @Published var isTrading = false
    @Published var latestLog = ""
    
    private var tradingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    
    func toggleTrading() {
        isTrading.toggle()
        if isTrading {
            startTrading()
        } else {
            stopTrading()
        }
    }
    
    private func startTrading() {
        tradingTask = Task {
            while isTrading {
                await performTradingCycle()
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1초 대기
            }
        }
    }
    
    private func stopTrading() {
        tradingTask?.cancel()
        sellAllHoldings()
    }
    
    private func performTradingCycle() async {
        do {
            let markets = try await DatabaseManager.shared.fetchMarkets()
            for market in markets {
                let prices = try await DatabaseManager.shared.DashBoardMarketPrices(for: market.id)
                if let tradingSignal = analyzePrices(prices) {
                    executeTrade(market: market, signal: tradingSignal)
                }
            }
        } catch {
            latestLog = "Error in trading cycle: \(error.localizedDescription)"
        }
    }
    
    private func analyzePrices(_ prices: [MarketPrice]) -> TradingSignal? {
        guard prices.count >= 20 else { return nil }  // 최소 20개의 데이터 포인트 필요

        let closePrices = prices.map { $0.tradePrice }
        let volumes = prices.map { $0.candleAccTradeVolume }

        let sma5 = calculateSMA(prices: closePrices, period: 5)
        let sma20 = calculateSMA(prices: closePrices, period: 20)
        let rsi = calculateRSI(prices: closePrices, period: 14)
        let (upperBand, lowerBand) = calculateBollingerBands(prices: closePrices, period: 20, multiplier: 2)

        let currentPrice = closePrices.last!
        let currentVolume = volumes.last!
        let averageVolume = volumes.suffix(5).reduce(0, +) / 5

        // 매수 신호
        if currentPrice > sma5 && sma5 > sma20 &&  // 상승 추세
           currentPrice < upperBand &&             // 상단 밴드에 닿지 않음
           rsi < 70 &&                             // 과매수 상태가 아님
           currentVolume > averageVolume * 1.5 {   // 거래량 증가
            return .buy
        }

        // 매도 신호
        if currentPrice < sma5 && sma5 < sma20 &&  // 하락 추세
           currentPrice > lowerBand &&             // 하단 밴드에 닿지 않음
           rsi > 30 &&                             // 과매도 상태가 아님
           currentVolume > averageVolume * 1.5 {   // 거래량 증가
            return .sell
        }

        return nil
    }
    
    private func calculateSMA(prices: [Double], period: Int) -> Double {
        guard prices.count >= period else { return 0 }
        let sum = prices.suffix(period).reduce(0, +)
        return sum / Double(period)
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

    private func calculateBollingerBands(prices: [Double], period: Int, multiplier: Double) -> (upper: Double, lower: Double) {
        let sma = calculateSMA(prices: prices, period: period)
        let stdDev = calculateStandardDeviation(prices: prices, period: period)
        let upper = sma + (multiplier * stdDev)
        let lower = sma - (multiplier * stdDev)
        return (upper, lower)
    }

    private func calculateStandardDeviation(prices: [Double], period: Int) -> Double {
        guard prices.count >= period else { return 0 }
        let slice = prices.suffix(period)
        let mean = slice.reduce(0, +) / Double(period)
        let variance = slice.map { pow($0 - mean, 2) }.reduce(0, +) / Double(period)
        return sqrt(variance)
    }
    
    private func executeTrade(market: Market, signal: TradingSignal) {
        // 실제 거래 로직을 여기에 구현합니다.
        // 이 예제에서는 로그만 출력합니다.
        latestLog = "\(signal == .buy ? "매수" : "매도") 신호: \(market.koreanName) (\(market.id))"
    }
    
    private func sellAllHoldings() {
        // 실제 모든 보유 종목 매도 로직을 여기에 구현합니다.
        latestLog = "모든 보유 종목 매도 실행"
    }
}

enum TradingSignal {
    case buy
    case sell
}

struct TradeTabView_Previews: PreviewProvider {
    static var previews: some View {
        TradeTabView()
    }
}

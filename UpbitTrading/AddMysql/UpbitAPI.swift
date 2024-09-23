import SwiftUI
import CryptoKit
import Foundation

// Extension to help with JWT creation
extension Dictionary {
    var jsonString: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: self, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension String {
    var base64URLEncoded: String {
        Data(self.utf8).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct RefreshButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
        }
    }
}

struct Market: Codable, Identifiable, Hashable {
    let id: String
    let koreanName: String
    
    enum CodingKeys: String, CodingKey {
        case id = "market"
        case koreanName = "korean_name"
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: Market, rhs: Market) -> Bool {
        return lhs.id == rhs.id
    }
}

struct UpbitErrorResponse: Codable {
    let error: UpbitError
}

struct UpbitError: Codable {
    let name: String
}

struct MarketPrice: Codable {
    let marketId: String
    let openingPrice: Double
    let highPrice: Double
    let lowPrice: Double
    let tradePrice: Double
    let timestamp: Date
    let candleAccTradeVolume: Double

    enum CodingKeys: String, CodingKey {
        case marketId = "market"
        case openingPrice = "opening_price"
        case highPrice = "high_price"
        case lowPrice = "low_price"
        case tradePrice = "trade_price"
        case timestamp = "candle_date_time_kst"
        case candleAccTradeVolume = "candle_acc_trade_volume"
    }
}

class UpbitAPI {
    static let shared = UpbitAPI()
    private init() {}
    
    func fetchMarkets(completion: @escaping (Result<[Market], Error>) -> Void) {
        guard let url = URL(string: "https://api.upbit.com/v1/market/all") else {
            completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        guard let accessKey = KeyManager.shared.getAccessKey(),
              let secretKey = KeyManager.shared.getSecretKey() else {
            completion(.failure(NSError(domain: "API Keys not found", code: 0, userInfo: nil)))
            return
        }
        
        let nonce = UUID().uuidString
        let timestamp = "\(Int64(Date().timeIntervalSince1970 * 1000))"
        let payload = "\(timestamp)\(nonce)\(request.httpMethod!)\(request.url!.path)"
        
        guard let secretKeyData = secretKey.data(using: .utf8),
              let payloadData = payload.data(using: .utf8) else {
            completion(.failure(NSError(domain: "Encoding error", code: 0, userInfo: nil)))
            return
        }
        
        let signature = HMAC<SHA256>.authenticationCode(for: payloadData, using: SymmetricKey(data: secretKeyData))
        let signatureString = Data(signature).base64EncodedString()
        
        // Create JWT token
        let jwtHeader = ["alg": "HS256", "typ": "JWT"].jsonString?.base64URLEncoded ?? ""
        let jwtPayload = ["access_key": accessKey, "nonce": nonce, "timestamp": timestamp].jsonString?.base64URLEncoded ?? ""
        let jwtSignature = Data(HMAC<SHA256>.authenticationCode(for: Data("\(jwtHeader).\(jwtPayload)".utf8), using: SymmetricKey(data: secretKeyData))).base64URLEncodedString()
        
        let jwt = "\(jwtHeader).\(jwtPayload).\(jwtSignature)"
        
        request.addValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: 0, userInfo: nil)))
                return
            }
            
            if let jsonString = String(data: data, encoding: .utf8) {
                print("Raw API Response: \(jsonString)")
            }
            
            do {
                if let errorResponse = try? JSONDecoder().decode(UpbitErrorResponse.self, from: data) {
                    completion(.failure(NSError(domain: "Upbit API Error", code: 0, userInfo: ["errorName": errorResponse.error.name])))
                    return
                }
                
                let decoder = JSONDecoder()
                let allMarkets = try decoder.decode([Market].self, from: data)
                let filteredMarkets = allMarkets
                    .filter { $0.id.hasPrefix("KRW-") }
                    .map { Market(id: $0.id, koreanName: $0.koreanName) }
                completion(.success(filteredMarkets))
            } catch {
                print("Decoding error: \(error)")
                completion(.failure(error))
            }
        }.resume()
    }
    
    func fetchPrices(for marketId: String) async throws -> [MarketPrice] {
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .year, value: -1, to: endDate)!
        
        let url = URL(string: "https://api.upbit.com/v1/candles/days?market=\(marketId)&count=365&to=\(formatDate(endDate))")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // ... (이전 코드와 동일한 인증 로직)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "Invalid response", code: 0, userInfo: nil)
        }

        if httpResponse.statusCode != 200 {
            if let errorResponse = try? JSONDecoder().decode(UpbitErrorResponse.self, from: data) {
                throw NSError(domain: "Upbit API Error", code: httpResponse.statusCode, userInfo: ["errorName": errorResponse.error.name])
            } else {
                throw NSError(domain: "HTTP Error", code: httpResponse.statusCode, userInfo: nil)
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
            if let date = formatter.date(from: dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
        }

        var prices = try decoder.decode([MarketPrice].self, from: data)
        
        // 1년 이내의 데이터만 필터링
        prices = prices.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
        
        // 데이터베이스에 저장
        let formattedPrices = prices.map { price in
            (price.marketId, price.openingPrice, price.highPrice, price.lowPrice, price.tradePrice, price.timestamp, price.candleAccTradeVolume)
        }
        try await DatabaseManager.shared.insertMarketPrices(formattedPrices)
        
        print("Fetched and saved \(prices.count) prices for \(marketId)")
        
        return prices
    }

    // 날짜를 문자열로 포맷하는 헬퍼 함수
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        return formatter.string(from: date)
    }
}

class MarketStore: ObservableObject {
    @Published var markets: [Market] = []
    @Published var status: String = ""
    @Published var progress: Float = 0.0
    
    // 종목 불러오기
    func fetchMarkets() {
        status = "마켓 정보 가져오는 중..."
        UpbitAPI.shared.fetchMarkets { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let fetchedMarkets):
                    self?.markets = fetchedMarkets
                    self?.status = "마켓 정보 가져오기 완료"
                    Task {
                        await self?.saveMarketsToDatabase(fetchedMarkets)
                    }
                case .failure(let error):
                    self?.status = "오류 발생: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func saveMarketsToDatabase(_ markets: [Market]) async {
        do {
            try await DatabaseManager.shared.insertOrUpdateMarkets(markets)
            await MainActor.run {
                status = "마켓 정보 데이터베이스 저장 완료"
            }
        } catch {
            await MainActor.run {
                status = "데이터베이스 저장 오류: \(error.localizedDescription)"
            }
        }
    }
    
    // 가격 불러오기
    func fetchAllPrices() {
        let krwMarkets = markets.filter { $0.id.hasPrefix("KRW-") }
        guard !krwMarkets.isEmpty else {
            status = "KRW 마켓이 없습니다. 먼저 마켓 정보를 가져와주세요."
            return
        }
        
        status = "모든 KRW 마켓의 가격 정보를 가져오는 중..."
        progress = 0.0
        
        Task {
            for (index, market) in krwMarkets.enumerated() {
                do {
                    try await fetchAndSavePrices(for: market)
                } catch {
                    print("Error processing \(market.id): \(error.localizedDescription)")
                }
                await MainActor.run {
                    progress = Float(index + 1) / Float(krwMarkets.count)
                    status = "\(market.koreanName) 처리 완료 (\(index + 1)/\(krwMarkets.count))"
                }
                
                // API 호출 사이에 지연 추가
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5초 대기
            }
            await MainActor.run {
                status = "모든 KRW 마켓의 가격 정보 처리 완료"
                progress = 1.0
            }
        }
    }
    
    private func fetchAndSavePrices(for market: Market) async throws {
        do {
            let prices = try await UpbitAPI.shared.fetchPrices(for: market.id)
            print("Fetched and saved \(prices.count) prices for \(market.id)")
        } catch {
            print("Error processing \(market.id): \(error)")
            throw error
        }
    }
}

struct FetchStocksView: View {
    @StateObject private var marketStore = MarketStore()
    @State private var searchText = ""
    @State private var selectedMarket: Market?
    @State private var marketPrices: [MarketPrice] = []

    var filteredMarkets: [Market] {
        if searchText.isEmpty {
            return marketStore.markets
        } else {
            return marketStore.markets.filter { $0.koreanName.localizedCaseInsensitiveContains(searchText) || $0.id.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                SearchBar(text: $searchText)
                    .padding(.horizontal)
                    .padding(.top)
                
                Text(marketStore.status)
                    .padding()
                
                if marketStore.progress > 0 {
                    ProgressView(value: marketStore.progress)
                        .padding()
                }

                List(filteredMarkets) { market in
                    MarketRow(market: market)
                        .onTapGesture {
                            selectedMarket = market
                            loadMarketPrices(for: market)
                        }
                }
            }
            .frame(minWidth: 250)
            .navigationTitle("Upbit 마켓")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button("마켓 정보 가져오기") {
                        marketStore.fetchMarkets()
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button("전체 종목 가격 가져오기") {
                        marketStore.fetchAllPrices()
                    }
                    .disabled(marketStore.markets.isEmpty)
                }
            }
            
            if let selectedMarket = selectedMarket {
                MarketPriceView(market: selectedMarket, prices: marketPrices)
            } else {
                Text("종목을 선택하세요")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func loadMarketPrices(for market: Market) {
        Task {
            do {
                marketPrices = try await DatabaseManager.shared.fetchMarketPrices(for: market.id)
            } catch {
                print("Error loading prices for \(market.id): \(error)")
            }
        }
    }
}

struct MarketPriceView: View {
    let market: Market
    let prices: [MarketPrice]
    
    var body: some View {
        VStack {
            Text("\(market.koreanName) (\(market.id)) 가격 정보")
                .font(.headline)
                .padding()
            
            if prices.isEmpty {
                Text("가격 정보가 없습니다.")
            } else {
                List(prices, id: \.timestamp) { price in
                    HStack {
                        Text(formatDate(price.timestamp))
                            .frame(width: 100, alignment: .leading)
                        Spacer()
                        Text("시가: \(formatPrice(price.openingPrice))")
                        Spacer()
                        Text("종가: \(formatPrice(price.tradePrice))")
                    }
                }
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    private func formatPrice(_ price: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: price)) ?? ""
    }
}
// SearchBar 구조체
struct SearchBar: View {
    @Binding var text: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)
            TextField("검색", text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
            }
        }
    }
}

// MarketRow 구조체
struct MarketRow: View {
    let market: Market
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(market.koreanName)
                    .font(.headline)
                Text(market.id)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// 미리보기 프로바이더
struct FetchStocksView_Previews: PreviewProvider {
    static var previews: some View {
        FetchStocksView()
    }
}

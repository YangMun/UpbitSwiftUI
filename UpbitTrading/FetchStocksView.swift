import SwiftUI
import CryptoKit
import Foundation

struct Market: Codable, Identifiable {
    let id: String
    let koreanName: String
    
    enum CodingKeys: String, CodingKey {
        case id = "market"
        case koreanName = "korean_name"
    }
}

struct UpbitErrorResponse: Codable {
    let error: UpbitError
}

struct UpbitError: Codable {
    let name: String
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
}

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

// ... (앞서 제공한 UpbitAPI 클래스 및 관련 구조체, 익스텐션 코드가 여기에 위치합니다)

class MarketStore: ObservableObject {
    @Published var markets: [Market] = []
    
    func saveMarkets(_ newMarkets: [Market]) {
        markets = newMarkets
    }
}

struct FetchStocksView: View {
    @StateObject private var marketStore = MarketStore()
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        VStack {
            Text("종목 가져오기")
                .font(.largeTitle)
            
            if isLoading {
                ProgressView("데이터 로딩 중...")
            } else if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
            } else {
                List(marketStore.markets) { market in
                    VStack(alignment: .leading) {
                        Text(market.koreanName)
                            .font(.headline)
                        Text(market.id)
                            .font(.caption)
                    }
                }
            }
            
            Button(action: fetchStocks) {
                Text("종목 불러오기")
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding()
        }
    }
    
    func fetchStocks() {
        isLoading = true
        errorMessage = nil
        
        UpbitAPI.shared.fetchMarkets { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let fetchedMarkets):
                    self.marketStore.saveMarkets(fetchedMarkets)
                case .failure(let error):
                    if let nsError = error as NSError?, let errorName = nsError.userInfo["errorName"] as? String {
                        self.errorMessage = "API Error: \(errorName)"
                    } else {
                        self.errorMessage = "Error: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}

struct FetchStocksView_Previews: PreviewProvider {
    static var previews: some View {
        FetchStocksView()
    }
}

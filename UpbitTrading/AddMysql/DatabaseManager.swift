import Foundation
import MySQLKit
import NIO
import Logging

class DatabaseManager {
    static let shared = DatabaseManager()
    private init() {}
    private func setupDatabaseConnection(eventLoopGroup: EventLoopGroup) async throws -> MySQLConnection {
        // Info.plist에서 데이터베이스 설정 정보 가져오기
        guard let infoDict = Bundle.main.infoDictionary,
              let hostname = infoDict["DatabaseHost"] as? String,
              let portString = infoDict["DatabasePort"] as? String, let port = Int(portString),
              let username = infoDict["DatabaseUsername"] as? String,
              let password = infoDict["DatabasePassword"] as? String,
              let database = infoDict["DatabaseName"] as? String else {
            throw NSError(domain: "DatabaseError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Database configuration is missing in Info.plist"])
        }
        
        let mysqlConfiguration = MySQLConfiguration(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: database,
            tlsConfiguration: .forClient(certificateVerification: .none)
        )
        
        let address = try await mysqlConfiguration.address()
        return try await MySQLConnection.connect(
            to: address,
            username: mysqlConfiguration.username,
            database: mysqlConfiguration.database!,
            password: mysqlConfiguration.password,
            tlsConfiguration: mysqlConfiguration.tlsConfiguration,
            logger: Logger(label: "mysql"),
            on: eventLoopGroup.next()
        ).get()
    }
    
    
    
    func insertOrUpdateMarkets(_ markets: [Market]) async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? eventLoopGroup.syncShutdownGracefully()
        }
        
        let conn = try await setupDatabaseConnection(eventLoopGroup: eventLoopGroup)
        defer { try? conn.close().wait() }
        
        // Step 1: 데이터베이스에서 현재 존재하는 market_id를 가져오기
        let existingMarketsQuery = "SELECT market_id FROM markets"
        let rows = try await conn.query(existingMarketsQuery).get()
        
        // 현재 데이터베이스에 존재하는 market_id 목록
        let existingMarketIds = Set(rows.compactMap { row in
            row.column("market_id")?.string
        })
        
        // 주어진 markets 목록에서의 market_id
        let incomingMarketIds = Set(markets.map { $0.id })
        
        // Step 2: 삭제할 종목들 (주어진 목록에 없는 종목)
        let marketsToDelete = existingMarketIds.subtracting(incomingMarketIds)
        if !marketsToDelete.isEmpty {
            let deleteQuery = """
            DELETE FROM markets WHERE market_id IN (\(marketsToDelete.map { _ in "?" }.joined(separator: ",")))
            """
            _ = try await conn.query(deleteQuery, marketsToDelete.map { MySQLData(string: $0) }).get()
        }
        
        // Step 3: 삽입 또는 업데이트
        for market in markets {
            let query = """
            INSERT INTO markets (market_id, korean_name)
            VALUES (?, ?)
            ON DUPLICATE KEY UPDATE
            korean_name = VALUES(korean_name),
            updated_at = CURRENT_TIMESTAMP
            """
            
            _ = try await conn.query(query, [
                MySQLData(string: market.id),
                MySQLData(string: market.koreanName)
            ]).get()
        }
    }
    
    func insertMarketPrices(_ prices: [(String, String, Double, Double, Double, Double, Date, Double)]) async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? eventLoopGroup.syncShutdownGracefully()
        }
        
        let conn = try await setupDatabaseConnection(eventLoopGroup: eventLoopGroup)
        defer { try? conn.close().wait() }
        
        let query = """
        INSERT INTO market_prices (market_id, korean_name, opening_price, high_price, low_price, trade_price, timestamp, candle_acc_trade_volume)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        
        print("Attempting to insert \(prices.count) records into market_prices table")
        
        do {
            // 트랜잭션 시작
            _ = try await conn.simpleQuery("START TRANSACTION").get()
            
            for (marketId, koreanName, openingPrice, highPrice, lowPrice, tradePrice, timestamp, volume) in prices {
                do {
                    _ = try await conn.query(query, [
                        MySQLData(string: marketId),
                        MySQLData(string: koreanName),
                        MySQLData(double: openingPrice),
                        MySQLData(double: highPrice),
                        MySQLData(double: lowPrice),
                        MySQLData(double: tradePrice),
                        MySQLData(date: timestamp),
                        MySQLData(double: volume)
                    ]).get()
                } catch {
                    print("Error inserting data for \(marketId): \(error)")
                    // 롤백
                    _ = try await conn.simpleQuery("ROLLBACK").get()
                    throw error
                }
            }
            
            // 커밋
            _ = try await conn.simpleQuery("COMMIT").get()
            print("Successfully inserted \(prices.count) records into market_prices table")
        } catch {
            print("Transaction failed: \(error)")
            // 롤백
            try? await conn.simpleQuery("ROLLBACK").get()
            throw error
        }
    }
    
    func fetchMarketPrices(for marketId: String) async throws -> [MarketPrice] {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? eventLoopGroup.syncShutdownGracefully()
        }
        
        let conn = try await setupDatabaseConnection(eventLoopGroup: eventLoopGroup)
        defer { try? conn.close().wait() }
        
        let query = """
        SELECT DISTINCT DATE(timestamp) as date,
               FIRST_VALUE(market_id) OVER (PARTITION BY DATE(timestamp) ORDER BY timestamp DESC) as market_id,
               FIRST_VALUE(korean_name) OVER (PARTITION BY DATE(timestamp) ORDER BY timestamp DESC) as korean_name,
               FIRST_VALUE(opening_price) OVER (PARTITION BY DATE(timestamp) ORDER BY timestamp DESC) as opening_price,
               FIRST_VALUE(high_price) OVER (PARTITION BY DATE(timestamp) ORDER BY timestamp DESC) as high_price,
               FIRST_VALUE(low_price) OVER (PARTITION BY DATE(timestamp) ORDER BY timestamp DESC) as low_price,
               FIRST_VALUE(trade_price) OVER (PARTITION BY DATE(timestamp) ORDER BY timestamp DESC) as trade_price,
               FIRST_VALUE(timestamp) OVER (PARTITION BY DATE(timestamp) ORDER BY timestamp DESC) as timestamp,
               FIRST_VALUE(candle_acc_trade_volume) OVER (PARTITION BY DATE(timestamp) ORDER BY timestamp DESC) as candle_acc_trade_volume
        FROM market_prices
        WHERE market_id = ?
          AND timestamp >= DATE_SUB(CURDATE(), INTERVAL 1 YEAR)
        ORDER BY date DESC
        """
        
        let rows = try await conn.query(query, [MySQLData(string: marketId)]).get()
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        
        return try rows.map { row in
            let timestamp = row.column("timestamp")?.date ?? Date()
            let marketPriceData: [String: Any] = [
                "market": row.column("market_id")?.string ?? "",
                "korean_name": row.column("korean_name")?.string ?? "",
                "opening_price": row.column("opening_price")?.double ?? 0,
                "high_price": row.column("high_price")?.double ?? 0,
                "low_price": row.column("low_price")?.double ?? 0,
                "trade_price": row.column("trade_price")?.double ?? 0,
                "candle_date_time_kst": dateFormatter.string(from: timestamp),
                "candle_acc_trade_volume": row.column("candle_acc_trade_volume")?.double ?? 0
            ]
            
            let jsonData = try JSONSerialization.data(withJSONObject: marketPriceData)
            return try JSONDecoder().decode(MarketPrice.self, from: jsonData)
        }
    }

    
    func DashBoardMarketPrices(for marketId: String) async throws -> [MarketPrice] {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? eventLoopGroup.syncShutdownGracefully()
        }
        
        let conn = try await setupDatabaseConnection(eventLoopGroup: eventLoopGroup)
        defer { try? conn.close().wait() }
        
        let query = """
        SELECT market_id, korean_name, opening_price, high_price, low_price, trade_price, timestamp, candle_acc_trade_volume
        FROM market_prices
        WHERE market_id = ?
        AND timestamp >= DATE_SUB(NOW(), INTERVAL 1 WEEK)
        ORDER BY timestamp ASC
        """
        
        let rows = try await conn.query(query, [MySQLData(string: marketId)]).get()
        
        return try rows.map { row in
            let timestamp = row.column("timestamp")?.date ?? Date()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            dateFormatter.timeZone = TimeZone(identifier: "Asia/Seoul")
            
            let marketPriceData: [String: Any] = [
                "market": row.column("market_id")?.string ?? "",
                "korean_name": row.column("korean_name")?.string ?? "",
                "opening_price": row.column("opening_price")?.double ?? 0,
                "high_price": row.column("high_price")?.double ?? 0,
                "low_price": row.column("low_price")?.double ?? 0,
                "trade_price": row.column("trade_price")?.double ?? 0,
                "candle_date_time_kst": dateFormatter.string(from: timestamp),
                "candle_acc_trade_volume": row.column("candle_acc_trade_volume")?.double ?? 0
            ]
            
            let jsonData = try JSONSerialization.data(withJSONObject: marketPriceData)
            return try JSONDecoder().decode(MarketPrice.self, from: jsonData)
        }
    }
    
    func fetchMarkets() async throws -> [Market] {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? eventLoopGroup.syncShutdownGracefully()
        }
        
        let conn = try await setupDatabaseConnection(eventLoopGroup: eventLoopGroup)
        defer { try? conn.close().wait() }
        
        let query = "SELECT market_id, korean_name FROM markets WHERE market_id LIKE 'KRW-%'"
        let rows = try await conn.query(query).get()
        
        return try rows.map { row in
            guard let marketId = row.column("market_id")?.string,
                  let koreanName = row.column("korean_name")?.string else {
                throw NSError(domain: "DatabaseError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid market data"])
            }
            return Market(id: marketId, koreanName: koreanName)
        }
    }
    
    func getLatestTimestamp(for marketId: String) async throws -> Date? {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? eventLoopGroup.syncShutdownGracefully()
        }
        
        let conn = try await setupDatabaseConnection(eventLoopGroup: eventLoopGroup)
        defer { try? conn.close().wait() }
        
        let query = "SELECT MAX(timestamp) as latest_timestamp FROM market_prices WHERE market_id = ?"
        let rows = try await conn.query(query, [MySQLData(string: marketId)]).get()
        
        return rows.first?.column("latest_timestamp")?.date
    }
}

extension DateFormatter {
    static let yyyyMMddTHHmmss: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        return formatter
    }()
}

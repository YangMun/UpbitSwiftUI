import Foundation
import MySQLKit
import NIO
import Logging

class DatabaseManager {
    static let shared = DatabaseManager()
    private init() {}
    
    func insertOrUpdateMarkets(_ markets: [Market]) async throws {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? eventLoopGroup.syncShutdownGracefully()
        }
        
        let logger = Logger(label: "mysql")
        
        // Info.plist에서 데이터베이스 설정 정보 가져오기
        guard let infoDict = Bundle.main.infoDictionary,
              let hostname = infoDict["DatabaseHost"] as? String,
              let portString = infoDict["DatabasePort"] as? String, let port = Int(portString),
              let username = infoDict["DatabaseUsername"] as? String,
              let password = infoDict["DatabasePassword"] as? String,
              let database = infoDict["DatabaseName"] as? String else {
            fatalError("Database configuration is missing in Info.plist")
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
        let conn = try await MySQLConnection.connect(
            to: address,
            username: mysqlConfiguration.username,
            database: mysqlConfiguration.database!,
            password: mysqlConfiguration.password,
            tlsConfiguration: mysqlConfiguration.tlsConfiguration,
            logger: logger,
            on: eventLoopGroup.next()
        ).get()
        
        defer {
            try? conn.close().wait()
        }
        
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
}

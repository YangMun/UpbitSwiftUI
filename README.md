# 업비트 자동화 프로그래밍: 출근할 때 시작해서 퇴근할 때 끄자

## 사용 방법
  - Info.plist 파일
    - Upbit API : Access Key, Secret Key 저장
    - DatabaseHost, DatabasePort, DatabaseUsername, DatabasePassword, DatabaseName 저장
   

### 1일차 (Day 1)
- **주요 작업**:
  - `UpbitAPI 파일`
    - API를 통해 데이터 추출
    - `FetchStocksView`  "마켓 정보 가져오기" 버튼을 통해 아래 기능 수행
   
  - `DatabaseManager 파일`
    - Mysql 연동 후 DB에 저장하는 Insert문 작성
   
### 2일차 (Day 2)
- **주요 작업**:
  - 각 종목에 대한 365일 전의 가격에서 200개의 가격 저장
 
### 3일차 (Day 3)
- **주요 작업**:
  - 각 종목에 대한 365일 전의 가격에서 400개로 수정
    - 만약 상장일이 365이 안 된다면 상장일로부터 전체 값 저장
   
### 4일차 (Day 4)
- **주요 작업**:
  - 해당 종목을 클릭시 1년치의 가격 정보를 띄움
  - 대시보드 창 추가
 
### 5일차 (Day 5)
- **주요 작업**:
  - getLatestTimestamp() 를 통해 최신 데이터만 DB에 추가
  - market_prices 테이블에 한글이름의 종목 컬럼 추가
  - `TradeView`생성
    - Trade On(Off)에 따라 매수 매도 진행 UI
    - 로그 띄워줄 UI
    - 매수,매도 executeTrade() 함수 구현

## To-Do List
- [X] 종목 Mysql에 저장
- [X] 종목에 대한 값 
- [ ] 개수에 대한 변동과 이미 업데이트 되었다면 마지막 업데이트 기준 "-" 하여 업데이트 하기
- [X] market_prices 테이블에 한글 이름도 추가하기(Ex.비트코인)
- [X] 스캘핑 + RSI 기법을 통해 매수 매도 기능 구현
- [X] 매수 매도 기능 구현
- [ ] Turn Off 버튼 클릭 시 보유중인 종목 시장가로 매도

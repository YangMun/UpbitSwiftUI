# 업비트 자동화 프로그래밍: 출근할 때 시작해서 퇴근할 때 끄자

## 사용 방법
  - Info.plist 파일
    - Upbit API : Access Key, Secret Key 저장
    - DatabaseHost, DatabasePort, DatabaseUsername, DatabasePassword, DatabaseName 저장
    - 
   

### 1일차 (Day 1)
- **주요 작업**:
  - `UpbitAPI 파일`
    - API를 통해 데이터 추출
    - `FetchStocksView`  "마켓 정보 가져오기" 버튼을 통해 아래 기능 수행
   
  - `DatabaseManager 파일`
    - Mysql 연동 후 DB에 저장하는 Insert문 작성


## To-Do List
- [X] 종목 Mysql에 저장
- [ ] 종목에 대한 값 (1년치 값 저장하기)

# Day 06：DELETE 事件傳播 —— 從 MV 到下游 Table

示範當 GROUP BY 的所有 row 都被刪除時，MV 會自動產生 DELETE 事件，Sink 再把這個 DELETE 事件寫進下游 Table。

## 環境需求

- Docker（建議 v20+）
- `psql`（或 DBeaver / 任何支援 PostgreSQL 協議的工具）

psql 安裝確認：

```bash
psql --version
```

沒有的話：

```bash
# macOS
brew install libpq && brew link --force libpq

# Ubuntu / Debian
sudo apt-get install postgresql-client
```

---

## 步驟一：啟動 RisingWave

```bash
docker compose up -d
```

等 healthcheck 通過（約 10–20 秒）：

```bash
docker compose ps
# STATUS 欄位顯示 healthy 才算好
```

> Playground 模式是單節點、一鍵啟動，適合本機實驗。所有資料存在記憶體，容器停掉就清空。

---

## 步驟二：連線進去

```bash
psql -h localhost -p 4566 -d dev -U root
```

連線成功會看到：

```
psql (14.x, server 9.5.0)
dev=#
```

---

## 步驟三：執行 SQL

依序貼入（或用 `\i` 載入檔案）：

```bash
# 在 psql 內
\i setup.sql     -- 建立 Table / MV / Sink
\i demo.sql      -- 執行 INSERT / DELETE，觀察傳播
\i teardown.sql  -- 清理（選用）
```

或用一行搞定：

```bash
psql -h localhost -p 4566 -d dev -U root \
  -f setup.sql \
  -f demo.sql
```

---

## 步驟四：清理環境

```bash
# 清掉 RisingWave 裡的物件
psql -h localhost -p 4566 -d dev -U root -f teardown.sql

# 停掉容器
docker compose down
```

---

## 預期觀察結果

| 階段 | 操作 | user_summary 內容 |
|------|------|------------------|
| Part 1 | INSERT 3 筆訂單 | user_id=42（2筆）、user_id=99（1筆）|
| Part 2 | DELETE user_id=42 的所有訂單 | 只剩 user_id=99，42 **消失** |
| Part 3（彩蛋）| 重新 INSERT user_id=42 | 42 重新出現，order_count 從 1 開始 |

Part 2 的關鍵：`orders` 裡 user_id=42 全部刪除後，`mv_user_summary` 的 GROUP BY 沒有任何輸出，
RisingWave 內部自動產生 `DELETE (user_id=42)` 事件，Sink 忠實寫進 `user_summary`。

---

## 快速排錯

| 症狀 | 可能原因 | 處理方式 |
|------|---------|---------|
| `psql: could not connect` | 容器還沒好 | 等 `docker compose ps` 顯示 healthy |
| `ERROR: table "orders" already exists` | 上次沒 teardown | 先跑 `teardown.sql` 再重跑 |
| `SELECT * FROM user_summary` 查詢為空 | Sink 還沒追上 | 等 1–2 秒再查 |

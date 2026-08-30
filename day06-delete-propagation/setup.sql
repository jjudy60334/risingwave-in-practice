-- Day 06：DELETE 事件傳播 —— 環境建置
-- 環境需求：任何 RisingWave 連線（psql / DBeaver 均可）
-- 執行順序：setup.sql → demo.sql → teardown.sql

-- Step 1：資料來源（用 Table 模擬 CDC 來源，不需要 Kafka）
CREATE TABLE orders (
    order_id  INT PRIMARY KEY,
    user_id   INT,
    amount    DECIMAL
);

-- Step 2：MV 統計每個 user 的訂單總金額
--         當 user 的所有訂單都被刪除，MV 會產生 DELETE 事件
CREATE MATERIALIZED VIEW mv_user_summary AS
SELECT
    user_id,
    COUNT(*)     AS order_count,
    SUM(amount)  AS total_amount
FROM orders
GROUP BY user_id;

-- Step 3：承接 MV 結果的 Table（扮演 DWS 層）
CREATE TABLE user_summary (
    user_id      INT PRIMARY KEY,
    order_count  BIGINT,
    total_amount DECIMAL
);

-- Step 4：Sink 把 MV 的 CDC 事件（含 DELETE）寫進 Table
--         CREATE SINK INTO 不需要 WITH 子句：
--         Upsert 語意由 user_summary 的 PRIMARY KEY (user_id) 自動驅動
CREATE SINK sink_user_summary
INTO user_summary
FROM mv_user_summary;

-- Step 5（選用）：用 AS CHANGELOG 把 mv_user_summary 每一筆變更記錄下來
--   必須在 demo 之前就建好，才會捕捉到後續的 Insert / Update / Delete 序列；
--   demo 跑完後 SELECT 這張表，就能對照文章裡的 changelog 表格。
--   changelog_op 值：1=Insert、2=Delete、3=UpdateInsert、4=UpdateDelete
CREATE MATERIALIZED VIEW mv_user_summary_changelog AS
WITH cl AS CHANGELOG FROM mv_user_summary
SELECT
    user_id,
    order_count,
    total_amount,
    changelog_op,
    _changelog_row_id
FROM cl;

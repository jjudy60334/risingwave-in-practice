-- ClickHouse MV demo：MV 是 INSERT 觸發器，UPDATE / DELETE 是盲點
-- 跑法：docker compose exec -T clickhouse clickhouse-client --multiquery < demo.sql

DROP TABLE IF EXISTS orders_summary_mv;
DROP TABLE IF EXISTS orders_summary;
DROP TABLE IF EXISTS orders_raw;

-- 來源表
CREATE TABLE orders_raw (
    order_id   UInt64,
    product_id String,
    amount     Float64,
    event_time DateTime DEFAULT now()
) ENGINE = MergeTree ORDER BY order_id;

-- 聚合結果表（SummingMergeTree 會在背景 merge 時把同 key 相加）
CREATE TABLE orders_summary (
    product_id   String,
    order_count  UInt64,
    total_amount Float64
) ENGINE = SummingMergeTree ORDER BY product_id;

-- MV：每次對 orders_raw 的 INSERT 觸發，把增量寫進 orders_summary
CREATE MATERIALIZED VIEW orders_summary_mv TO orders_summary AS
SELECT product_id, count() AS order_count, sum(amount) AS total_amount
FROM orders_raw
GROUP BY product_id;

-- 寫入 3 筆
INSERT INTO orders_raw (order_id, product_id, amount) VALUES
    (1, 'A', 100), (2, 'A', 200), (3, 'B', 80);

-- 查聚合（外層再 sum + GROUP BY，避免 SummingMergeTree 尚未 merge 時看到多列）
SELECT '寫入後' AS stage, product_id,
       sum(order_count) AS order_count, sum(total_amount) AS total_amount
FROM orders_summary GROUP BY product_id ORDER BY product_id;
-- 預期：A | 2 | 300 ；B | 1 | 80

-- ★ 重點：刪掉來源的一筆訂單（mutation，不是 INSERT）
ALTER TABLE orders_raw DELETE WHERE order_id = 2 SETTINGS mutations_sync = 1;

-- 先證明 DELETE 真的生效了（否則無法排除「mutation 沒跑」的可能）
SELECT '來源表 orders_raw' AS stage, count() AS rows, sum(amount) AS total FROM orders_raw;
-- 預期：2 筆 | 180 —— 來源確實少了一筆

SELECT '刪 order_id=2 後' AS stage, product_id,
       sum(order_count) AS order_count, sum(total_amount) AS total_amount
FROM orders_summary GROUP BY product_id ORDER BY product_id;
-- 預期：A 仍然是 2 | 300  ←← DELETE 對 MV 完全隱形（這就是文章的核心示範）
-- orders_raw 少了一筆，但 orders_summary 沒有回退。

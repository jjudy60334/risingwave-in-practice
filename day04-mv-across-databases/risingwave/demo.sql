-- RisingWave MV demo：事件驅動、逐筆增量，DELETE 也會反映
-- 跑法：psql -h localhost -p 4566 -d dev -U root -f demo.sql

DROP MATERIALIZED VIEW IF EXISTS orders_summary;
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    order_id   INT PRIMARY KEY,
    product_id VARCHAR,
    amount     DECIMAL
);

-- MV：持續運行、增量維護（不需要觸發器、不需要 refresh）
CREATE MATERIALIZED VIEW orders_summary AS
SELECT product_id, COUNT(*) AS order_count, SUM(amount) AS total_amount
FROM orders
GROUP BY product_id;

INSERT INTO orders VALUES (1,'A',100),(2,'A',200),(3,'B',80);
FLUSH;   -- 強制推進一個 barrier，讓上面的寫入反映到 MV

SELECT '寫入後' AS stage, * FROM orders_summary ORDER BY product_id;
-- 預期：A | 2 | 300 ；B | 1 | 80

-- ★ 重點：刪掉一筆訂單
DELETE FROM orders WHERE order_id = 2;
FLUSH;

SELECT '刪 order_id=2 後' AS stage, * FROM orders_summary ORDER BY product_id;
-- 預期：A | 1 | 100 ；B | 1 | 80  ←← MV 自動反映了 DELETE
-- 跟 ClickHouse 對照：同樣刪一筆，RisingWave 的聚合馬上跟著變。

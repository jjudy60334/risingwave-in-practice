-- StarRocks Async MV demo：靠 REFRESH 才更新（非事件驅動即時）
-- 跑法（mysql client 會被下面的 `--` 註解卡住，先 strip 掉再送）：
--   sed 's/--.*//' demo.sql | docker run --rm -i --network host mysql:8 mysql -h127.0.0.1 -P9030 -uroot
-- 前提：docker compose up -d 後，等 SHOW COMPUTE NODES 出現 Alive: true

CREATE DATABASE IF NOT EXISTS mvdemo;
USE mvdemo;

DROP MATERIALIZED VIEW IF EXISTS orders_summary;
DROP TABLE IF EXISTS orders;

-- 用 PRIMARY KEY 表，方便待會 DELETE
CREATE TABLE orders (
    order_id   INT,
    product_id VARCHAR(16),
    amount     DECIMAL(10, 2)
)
PRIMARY KEY(order_id)
DISTRIBUTED BY HASH(order_id);

INSERT INTO orders VALUES (1,'A',100),(2,'A',200),(3,'B',80);

-- Async MV：定義聚合，靠 refresh 維護（這裡先手動 refresh）
CREATE MATERIALIZED VIEW orders_summary
REFRESH ASYNC
AS
SELECT product_id, COUNT(*) AS order_count, SUM(amount) AS total_amount
FROM orders
GROUP BY product_id;

REFRESH MATERIALIZED VIEW orders_summary WITH SYNC MODE;
SELECT '寫入 + refresh 後' AS stage, * FROM orders_summary ORDER BY product_id;
-- 預期：A | 2 | 300 ；B | 1 | 80

-- ★ 重點：刪一筆，看「refresh 前 vs refresh 後」
DELETE FROM orders WHERE order_id = 2;

SELECT 'refresh 前（可能還是舊值）' AS stage, * FROM orders_summary ORDER BY product_id;
-- Async MV 不是事件驅動：refresh 尚未跑，可能還看到 A | 2 | 300

REFRESH MATERIALIZED VIEW orders_summary WITH SYNC MODE;
SELECT 'refresh 後' AS stage, * FROM orders_summary ORDER BY product_id;
-- 預期：A | 1 | 100 ；B | 1 | 80
-- 重點：StarRocks 要等 refresh 才反映變更（對照 RisingWave 的事件驅動即時）。

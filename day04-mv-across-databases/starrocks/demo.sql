-- StarRocks MV demo：refresh 維護（整批重算），不是逐筆增量
-- 跑法（mysql client 會被 SQL 裡的 `--` 註解卡住，用 --skip-comments 讓 client 自己處理）：
--   docker run --rm -i --network host mysql:8 mysql --skip-comments -h127.0.0.1 -P9030 -uroot < demo.sql
-- 前提：docker compose up -d 後，等 SHOW COMPUTE NODES 出現 Alive: true

CREATE DATABASE IF NOT EXISTS mvdemo;
USE mvdemo;

DROP MATERIALIZED VIEW IF EXISTS orders_summary;
DROP MATERIALIZED VIEW IF EXISTS orders_summary_async;
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

-- 建兩個內容相同的 MV，差別只在 refresh 策略：
--   orders_summary        REFRESH MANUAL：只有你下 REFRESH 才更新
--   orders_summary_async  REFRESH ASYNC ：base table 變更會自動觸發 refresh
CREATE MATERIALIZED VIEW orders_summary
REFRESH MANUAL
AS
SELECT product_id, COUNT(*) AS order_count, SUM(amount) AS total_amount
FROM orders
GROUP BY product_id;

CREATE MATERIALIZED VIEW orders_summary_async
REFRESH ASYNC
AS
SELECT product_id, COUNT(*) AS order_count, SUM(amount) AS total_amount
FROM orders
GROUP BY product_id;

REFRESH MATERIALIZED VIEW orders_summary WITH SYNC MODE;
SELECT '寫入 + refresh 後' AS stage, * FROM orders_summary ORDER BY product_id;
-- 預期：A | 2 | 300 ；B | 1 | 80


-- ★ 重點：刪一筆，看兩個 MV 的反應
DELETE FROM orders WHERE order_id = 2;

SELECT 'MANUAL：refresh 前' AS stage, * FROM orders_summary ORDER BY product_id;
-- 預期：A 仍是 2 | 300 —— 沒下 REFRESH 就不會動

REFRESH MATERIALIZED VIEW orders_summary WITH SYNC MODE;
SELECT 'MANUAL：refresh 後' AS stage, * FROM orders_summary ORDER BY product_id;
-- 預期：A | 1 | 100

-- 現在看 ASYNC 那個：完全沒有手動 REFRESH，它自己會追上
SELECT SLEEP(3);
SELECT 'ASYNC：等 3 秒，未手動 refresh' AS stage, * FROM orders_summary_async ORDER BY product_id;
-- 預期：A | 1 | 100 —— 大約 1~2 秒就自動刷完了


-- ══════════════════════════════════════════════════════════════════
-- 所以「StarRocks 要手動刷新」是錯的印象。ASYNC 會自己追上，秒級。
--
-- 真正和 RisingWave 的差別不在「手動 vs 自動」，而在**刷新的方式**：
--   StarRocks   refresh 觸發後，以 partition 為單位**整批重算**
--               （預設 PCT，分區變更追蹤；單一 partition 內部是全部重算）
--   RisingWave  上游每來一個事件就**只更新受影響的那幾筆**，沒有 refresh 這回事
--
-- 資料量小的時候兩者看起來都「很快就對了」，差異要在資料量大、
-- 或 partition 切得大的時候才會顯現：StarRocks 重算一整片，RisingWave 只動一筆。
--
-- 另注意：本 demo 用的是**存算分離（shared-data）**部署，
-- 因此無法建立文章提到的 Sync MV（rollup）——
-- StarRocks 會回報 "not supported in shared data clusters"。
-- 要試 Sync MV 需改用 shared-nothing 部署。
-- ══════════════════════════════════════════════════════════════════

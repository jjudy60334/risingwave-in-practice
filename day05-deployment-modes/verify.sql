-- Day 05：驗證你現在跑的是哪一種部署模式
--
-- 這支 SQL 兩種模式（standalone / distributed）都能跑，重點是比較兩邊的輸出差異。
-- 用法：psql -h localhost -p 4566 -d dev -U root -f verify.sql

\echo '================================================================'
\echo 'Part 1：叢集裡有哪些節點？'
\echo '  standalone → 四個 worker 的 host 全是 0.0.0.0（同一個 process 內）'
\echo '  distributed → 四個 worker 各自有不同的容器主機名'
\echo '================================================================'

SELECT id,
       type,
       host,
       port,
       state,
       parallelism,
       started_at
FROM rw_catalog.rw_worker_nodes
ORDER BY id;

\echo ''
\echo '================================================================'
\echo 'Part 2：Compute Node 的「記憶體預算」對得上機器嗎？（文章坑 1）'
\echo '  system_total_memory_bytes 是 RisingWave 看到的「機器記憶體」，'
\echo '  跟你用 --total-memory-bytes / K8s memory limit 給的預算是兩回事。'
\echo '  兩者沒對齊，就是 OOMKilled 的來源。'
\echo '================================================================'

SELECT type,
       host,
       system_total_memory_bytes,
       round(system_total_memory_bytes / 1024.0 / 1024 / 1024, 2) AS system_memory_gib,
       system_total_cpu_cores
FROM rw_catalog.rw_worker_nodes
WHERE type IN ('WORKER_TYPE_COMPUTE_NODE', 'WORKER_TYPE_COMPACTOR')
ORDER BY id;

\echo ''
\echo '-- 本次實際給 Compute 的預算，要去容器日誌看（不是上面這個數字）：'
\echo '--   docker compose logs risingwave-standalone | grep -A8 "Memory outline"   # standalone'
\echo '--   docker compose logs compute-node          | grep -A8 "Memory outline"   # distributed'
\echo ''

\echo '================================================================'
\echo 'Part 3：建一個小工作負載，看 Actor 被排到哪個節點上'
\echo '================================================================'

DROP MATERIALIZED VIEW IF EXISTS mv_sales_by_city;
DROP TABLE IF EXISTS sales;

CREATE TABLE sales (
    id     INT PRIMARY KEY,
    city   VARCHAR,
    amount INT
);

CREATE MATERIALIZED VIEW mv_sales_by_city AS
SELECT city, count(*) AS orders, sum(amount) AS total
FROM sales
GROUP BY city;

INSERT INTO sales VALUES
    (1, 'Taipei',    100),
    (2, 'Taipei',    250),
    (3, 'Kaohsiung', 180),
    (4, 'Taichung',   90);

FLUSH;

SELECT * FROM mv_sales_by_city ORDER BY city;

\echo ''
\echo '-- Actor 分佈：worker_id 對得上 Part 1 的節點 id。'
\echo '-- distributed 模式把 compute-node scale 成 2 份後重跑，會看到 actor 分散到兩個 worker。'

SELECT a.worker_id,
       w.host,
       w.type,
       count(*) AS actor_count
FROM rw_catalog.rw_actors a
JOIN rw_catalog.rw_worker_nodes w ON w.id = a.worker_id
GROUP BY a.worker_id, w.host, w.type
ORDER BY a.worker_id;

\echo ''
\echo '================================================================'
\echo 'Part 4：狀態真的落到物件儲存了嗎？'
\echo '  上面的 FLUSH 會觸發一次 Checkpoint，把狀態寫進 MinIO。'
\echo '  打開 http://localhost:9400（帳密 hummockadmin / hummockadmin）'
\echo '  進 hummock001 bucket，就能看到 .data 檔——那就是你的 MV 狀態。'
\echo '  這也是文章坑 2 的檢查點：S3 權限不足，會在這一步才炸。'
\echo '================================================================'

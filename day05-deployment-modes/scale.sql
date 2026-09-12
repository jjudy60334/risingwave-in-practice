-- Day 05 附加實驗：加了一台 Compute Node，既有的 MV 會自己搬過去嗎？
--
-- 只適用 distributed 模式。前置步驟：
--   1. 先跑過 verify.sql（會建好 sales 與 mv_sales_by_city）
--   2. docker compose up -d --scale compute-node=2
--   3. psql ... -f scale.sql

\echo '=== 現在叢集有幾個 Compute Node？（應該看到兩個，IP 不同）==='
SELECT id, type, host, parallelism
FROM rw_catalog.rw_worker_nodes
ORDER BY id;

\echo ''
\echo '=== 既有 MV 的 Actor 分佈：全部還擠在原本那台 ==='
\echo '    這是重點——新節點加進來，既有的串流作業「不會」自動搬過去。'
SELECT a.worker_id, w.host, count(*) AS actor_count
FROM rw_catalog.rw_actors a
JOIN rw_catalog.rw_worker_nodes w ON w.id = a.worker_id
GROUP BY a.worker_id, w.host
ORDER BY a.worker_id;

\echo ''
\echo '=== 對照組：擴容之後「新建」的 MV，就會用到兩台 ==='
DROP MATERIALIZED VIEW IF EXISTS mv_after_scale;
CREATE MATERIALIZED VIEW mv_after_scale AS
SELECT city, count(*) AS orders FROM sales GROUP BY city;

SELECT a.worker_id, w.host, count(*) AS actor_count
FROM rw_catalog.rw_actors a
JOIN rw_catalog.rw_worker_nodes w ON w.id = a.worker_id
GROUP BY a.worker_id, w.host
ORDER BY a.worker_id;

\echo ''
\echo '=== 要讓既有 MV 也用到新節點，得明確叫它重新分配 ==='
ALTER MATERIALIZED VIEW mv_sales_by_city SET PARALLELISM = ADAPTIVE;

SELECT a.worker_id, w.host, count(*) AS actor_count
FROM rw_catalog.rw_actors a
JOIN rw_catalog.rw_worker_nodes w ON w.id = a.worker_id
GROUP BY a.worker_id, w.host
ORDER BY a.worker_id;

\echo ''
\echo '結論：擴容是兩件事——「加機器」和「讓既有作業用到新機器」。'
\echo '生產環境把 Compute Node 的 replicas 從 3 調到 5，如果沒有第二步，'
\echo '你會發現監控上多了兩台閒置的機器，而原本會 OOM 的那台還是繼續 OOM。'

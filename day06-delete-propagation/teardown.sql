-- Day 06：DELETE 事件傳播 —— 清理
-- 按順序執行（Sink 依賴 MV，MV 依賴 Table，需反向 DROP）

DROP SINK IF EXISTS sink_user_summary;
DROP MATERIALIZED VIEW IF EXISTS mv_user_summary_changelog;
DROP MATERIALIZED VIEW IF EXISTS mv_user_summary;
DROP TABLE IF EXISTS user_summary;
DROP TABLE IF EXISTS orders;

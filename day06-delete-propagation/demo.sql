-- Day 06：DELETE 事件傳播 —— Demo 步驟
-- 前提：已執行 setup.sql

-- ================================================================
-- Part 1：寫入資料，觀察 Table 被 Sink 自動填入
-- ================================================================

-- user 42 的第一筆訂單、加上 user 99 的訂單
INSERT INTO orders VALUES (1, 42, 100.00), (3, 99, 80.00);

-- 這個 FLUSH 是必要的：它把兩筆 INSERT 切成不同 epoch。
-- 少了它，下面那筆會和這筆併進同一個 epoch，changelog 就只會看到
-- 一列 Insert(42,2,350)，看不到 UpdateDelete / UpdateInsert 這一對。
FLUSH;

-- user 42 的第二筆訂單，分開成另一個 INSERT
-- （分開送才會落在不同 epoch，等下用 AS CHANGELOG 才看得到 Update；
--   若塞進同一個 INSERT，同 epoch 內會被合併成單一 Insert(42,2,350)）
INSERT INTO orders VALUES (2, 42, 250.00);

-- Sink INTO Table 是非同步的，查詢前先 FLUSH 確保已落地
FLUSH;

SELECT * FROM user_summary ORDER BY user_id;
-- 預期：
--  user_id | order_count | total_amount
-- ---------+-------------+--------------
--       42 |           2 |       350.00
--       99 |           1 |        80.00


-- ================================================================
-- Part 2：DELETE user 42 的所有訂單
--         觀察 DELETE 事件如何從 MV 傳播到 Table
-- ================================================================

DELETE FROM orders WHERE user_id = 42;

FLUSH;

SELECT * FROM user_summary ORDER BY user_id;
-- 預期：
--  user_id | order_count | total_amount
-- ---------+-------------+--------------
--       99 |           1 |        80.00
--
-- user_id=42 那筆消失了。
-- 原因：orders 裡 user_id=42 歸零後，mv_user_summary 的 GROUP BY
--       沒有任何 row 可輸出，內部自動產生 DELETE (user_id=42) 事件，
--       Sink 把這個 DELETE 事件寫進了 user_summary。


-- ================================================================
-- Part 3（彩蛋）：再加回一筆，該 key 重新出現
-- ================================================================

INSERT INTO orders VALUES (4, 42, 500.00);

FLUSH;

SELECT * FROM user_summary ORDER BY user_id;
-- 預期：
--  user_id | order_count | total_amount
-- ---------+-------------+--------------
--       42 |           1 |       500.00
--       99 |           1 |        80.00
--
-- user_id=42 重新出現。注意這是一筆全新的 Insert（不是 Update）——
-- 因為 key 在 Part 2 已經整個消失過，這裡是它重新出現，
-- order_count 從頭計算（前面的 2 筆已被刪除）。


-- ================================================================
-- Part 4：觀察完整的 changelog 序列（對照文章的 changelog 表格）
--         需要 setup.sql 有建 mv_user_summary_changelog
-- ================================================================

SELECT user_id, order_count, total_amount, changelog_op
FROM mv_user_summary_changelog
ORDER BY _changelog_row_id;
-- 預期（changelog_op：1=Insert 2=Delete 3=UpdateInsert 4=UpdateDelete）：
--  user_id | order_count | total_amount | changelog_op
-- ---------+-------------+--------------+--------------
--       42 |           1 |       100.00 |            1   -- Insert（第一筆訂單）
--       99 |           1 |        80.00 |            1   -- Insert（user 99）
--   ※ 前兩列在同一個 epoch，實際輸出順序不保證，對調也是正常的
--       42 |           1 |       100.00 |            4   -- UpdateDelete（撤回舊值）
--       42 |           2 |       350.00 |            3   -- UpdateInsert（寫入新值）
--       42 |           2 |       350.00 |            2   -- Delete（user 42 訂單刪光）
--       42 |           1 |       500.00 |            1   -- Insert（key 重新出現）


-- ================================================================
-- 延伸觀察：設計防禦——不想讓資料被刪除怎麼辦？
-- ================================================================

-- 用 COALESCE 確保 GROUP BY 沒資料時也輸出 0，而非 DELETE
-- （需重建 MV 才能看到效果，此處僅示意 SQL 寫法）
--
-- CREATE MATERIALIZED VIEW mv_user_summary_safe AS
-- SELECT
--     user_id,
--     COUNT(*)                      AS order_count,
--     COALESCE(SUM(amount), 0.00)   AS total_amount
-- FROM orders
-- GROUP BY user_id;
--
-- 注意：若 orders 裡完全沒有 user_id=42 的 row，
-- GROUP BY 本身就不會產生這個 user_id 的 row，
-- COALESCE 無法防止這種情況的 DELETE——
-- 真正的防禦需要在設計上保留 user 的靜態維度表。

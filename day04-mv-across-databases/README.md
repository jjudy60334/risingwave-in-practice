# Day 04：MV 跨系統行為對照（ClickHouse / StarRocks / RisingWave）

這是 Day 04「各家 MV 大不同」的可跑 companion。三個系統各起一套最小環境，跑**同一個場景**，親眼看差異：

> 建一個「每個 product 的訂單數與總金額」的 MV → 寫入 3 筆訂單 → **刪掉其中一筆** → 看聚合結果會不會跟著變。

| 系統 | 刪掉來源那筆後，MV 會不會變？ | 為什麼 | 但是 |
|---|---|---|---|
| **ClickHouse** | ❌ 不變 | MV 是 INSERT 觸發器，DELETE 對它隱形 | INSERT 端**近乎零延遲**、不需任何 refresh，這是它的強項；DELETE 要靠 `ReplacingMergeTree` + 版本號在外部補償（見文章） |
| **StarRocks** | ⏳ 靠 refresh 更新 | refresh 觸發後以 partition 為單位**整批重算** | `REFRESH ASYNC` **會自己追上**（實測約 1–2 秒），不需人工介入。差別不在「手動 vs 自動」，在「整批重算 vs 逐筆增量」 |
| **RisingWave** | ✅ 立刻變 | 事件驅動、逐筆增量，DELETE 也處理 | 沒有 refresh 這個旋鈕，上游來一筆就只更新受影響的那幾筆 |

> demo 會建**兩個** StarRocks MV（`REFRESH MANUAL` 與 `REFRESH ASYNC`），
> 讓你同時看到「不刷就不動」和「不用刷也會自己動」——避免得到「StarRocks 要人按刷新」的錯誤印象。

## 怎麼跑

先確認 Docker 有起來（OrbStack / Docker Desktop）。每個資料夾各自獨立：

```bash
cd clickhouse   # 或 starrocks / risingwave
docker compose up -d
# 等容器 ready（檢查指令見各 docker-compose.yml 頂端註解），再跑 demo.sql（指令見下）
docker compose down -v   # 收工
```

各系統的連線與跑法（沒有本機 client 也行，用容器版指令）：

- **ClickHouse**：
  ```bash
  docker compose exec -T clickhouse clickhouse-client --multiquery < demo.sql
  ```
- **RisingWave**：
  ```bash
  docker run --rm --network risingwave_default -v "$PWD/demo.sql:/demo.sql:ro" \
    postgres:16-alpine psql -h mvdemo-risingwave -p 4566 -d dev -U root -f /demo.sql
  ```
- **StarRocks**（先等 CN 註冊，約 30–40 秒）：
  ```bash
  # 等 ready
  docker run --rm --network starrocks_default mysql:8 \
    mysql -hstarrocks-fe -P9030 -uroot -e "SHOW COMPUTE NODES\G" | grep 'Alive: true'
  # 跑 demo（--skip-comments 讓 client 自己處理 SQL 註解）
  docker run --rm -i --network starrocks_default mysql:8 \
    mysql --skip-comments -hstarrocks-fe -P9030 -uroot < demo.sql
  ```

> **為什麼不用 `--network host`**：macOS 上只有 OrbStack 支援它；Docker Desktop 要到 4.34+
> 且必須在 Settings → Resources → Network 手動開啟，**預設是關的**。改用 compose 網路 +
> 容器名兩邊都能跑。（網路名是「資料夾名 + `_default`」，若你改過資料夾名請用
> `docker network ls` 確認。）

## ✅ 驗證狀態（2026-07，Apple Silicon / OrbStack 實跑，三家全通過）

| 系統 | 狀態 | 實跑結果 |
|---|---|---|
| **ClickHouse** | ✅ 通過 | 寫入後 A=2/300；**刪 order_id=2 後 A 仍 2/300**（DELETE 對 MV 隱形） |
| **RisingWave** | ✅ 通過 | 寫入後 A=2/300；**刪 order_id=2 後 A=1/100**（MV 立刻反映 DELETE） |
| **StarRocks** | ✅ 通過 | MANUAL MV：刪後未刷仍 A=2/300、`REFRESH` 後 A=1/100；ASYNC MV：**未手動刷新，約 1–2 秒自動變 A=1/100** |

- image tag：ClickHouse `24.8.14.39`、RisingWave `v3.0.3`、MinIO `RELEASE.2025-09-07T16-13-09Z`、mc `RELEASE.2025-08-13T08-35-41Z` 皆已釘死；StarRocks `fe-ubuntu`/`cn-ubuntu` 仍是滾動的 `3.3-latest`（官方未提供 patch 版 tag）。
- **請一次只跑一個 stack**，跑完 `docker compose down -v` 再跑下一個：ClickHouse 的 native TCP 與 StarRocks 的 MinIO 都用 9000，同時起會 `port is already allocated`。
- **StarRocks 為什麼用 FE+CN+MinIO（shared-data）而非 allin1**：實測 allin1 的內建 **BE 在本機（含原生 arm64）會 crash-loop、無法註冊**；改用官方**存算分離**架構（FE + Compute Node + 物件儲存）就穩定。三家 image 都有原生 arm64、Apple Silicon 直接跑。
- **這個選擇的副作用**：存算分離模式**無法建立文章提到的 Sync MV（rollup）**，會回報 `Creating synchronous materialized view(rollup) is not supported in shared data clusters`。想試 Sync MV 要改用 shared-nothing 部署。
- **資源**：StarRocks 這套穩態約 2.4GB（FE 1.65 + CN 0.42 + MinIO 0.32），8GB 機器很寬裕；但第一次要拉的 image 不小，請耐心等。
- **Apple Silicon 提醒**：不要對任何服務指定 `platform: linux/amd64`——強制 x86 模擬會讓 StarRocks 的 C++ 元件 crash。

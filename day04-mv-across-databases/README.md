# Day 04：MV 跨系統行為對照（ClickHouse / StarRocks / RisingWave）

這是 Day 04「各家 MV 大不同」的可跑 companion。三個系統各起一套最小環境，跑**同一個場景**，親眼看差異：

> 建一個「每個 product 的訂單數與總金額」的 MV → 寫入 3 筆訂單 → **刪掉其中一筆** → 看聚合結果會不會跟著變。

| 系統 | 刪掉來源那筆後，MV 會不會變？ | 為什麼 |
|---|---|---|
| **ClickHouse** | ❌ 不變 | MV 是 INSERT 觸發器，DELETE 對它隱形 |
| **StarRocks** | ⏳ 要 `REFRESH` 之後才變 | MV 靠 refresh，不是事件驅動 |
| **RisingWave** | ✅ 立刻變 | 事件驅動、逐筆增量，DELETE 也處理 |

## 怎麼跑

先確認 Docker 有起來（OrbStack / Docker Desktop）。每個資料夾各自獨立：

```bash
cd clickhouse   # 或 starrocks / risingwave
docker compose up -d
# 等容器 ready（檢查指令見各 docker-compose.yml 頂端註解），再跑 demo.sql（指令見下）
docker compose down -v   # 收工
```

各系統的連線與跑法（沒有本機 client 也行，用容器版指令）：

- **ClickHouse**：`docker compose exec -T clickhouse clickhouse-client --multiquery < demo.sql`
- **RisingWave**（需本機 `psql`，或用容器版）：
  `docker run --rm --network host -v "$PWD/demo.sql:/demo.sql:ro" postgres:16-alpine psql -h localhost -p 4566 -d dev -U root -f /demo.sql`
- **StarRocks**（先等 CN 註冊 `SHOW COMPUTE NODES` Alive: true，約 30–40 秒；**mysql client 會被 `--` 註解卡住，先 strip 掉**）：
  `sed 's/--.*//' demo.sql | docker run --rm -i --network host mysql:8 mysql -h127.0.0.1 -P9030 -uroot`

## ✅ 驗證狀態（2026-07，Apple Silicon / OrbStack 實跑，三家全通過）

| 系統 | 狀態 | 實跑結果 |
|---|---|---|
| **ClickHouse** | ✅ 通過 | 寫入後 A=2/300；**刪 order_id=2 後 A 仍 2/300**（DELETE 對 MV 隱形） |
| **RisingWave** | ✅ 通過 | 寫入後 A=2/300；**刪 order_id=2 後 A=1/100**（MV 立刻反映 DELETE） |
| **StarRocks** | ✅ 通過 | 刪後 refresh 前 A=2/300、**`REFRESH` 後 A=1/100**（要刷新才反映——非事件驅動） |

- image tag：ClickHouse `24.8`、RisingWave `v3.0.3`、StarRocks `fe-ubuntu`/`cn-ubuntu` `3.3-latest`、MinIO `latest`。
- **請一次只跑一個 stack**，跑完 `docker compose down -v` 再跑下一個：ClickHouse 的 native TCP 與 StarRocks 的 MinIO 都用 9000，同時起會 `port is already allocated`。
- **StarRocks 為什麼用 FE+CN+MinIO（shared-data）而非 allin1**：實測 allin1 的內建 **BE 在本機（含原生 arm64）會 crash-loop、無法註冊**；改用官方**存算分離**架構（FE + Compute Node + 物件儲存）就穩定。三家 image 都有原生 arm64、Apple Silicon 直接跑。
- **Apple Silicon 提醒**：不要對任何服務指定 `platform: linux/amd64`——強制 x86 模擬會讓 StarRocks 的 C++ 元件 crash。

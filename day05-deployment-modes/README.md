# Day 05：部署模式 —— standalone 與 distributed 到底差在哪

官方 `docker-compose.yml` 起的到底是「一個節點」還是「四個節點」？
這個範例把兩種模式並排跑一次，用同一支 SQL 驗證差異，順便把文章裡三個坑的
前兩個在本機重現出來。

跑完你會知道：

1. 官方 `docker-compose.yml` 是 **standalone**——四個元件在同一個 process 裡
2. `docker-compose-distributed.yml` 才是四個獨立節點，也是最接近生產的形狀
3. 怎麼用一句 SQL 確認自己現在跑的是哪一種
4. 「RisingWave 看到的機器記憶體」跟「你給它的記憶體預算」是兩回事（文章坑 1）
5. 加一台 Compute Node，既有的 MV **不會**自動搬過去

## 檔案

| 檔案 | 用途 |
|---|---|
| `standalone/docker-compose.yml` | 模式 A：四合一 process（官方 `docker-compose.yml` 的精簡版） |
| `distributed/docker-compose.yml` | 模式 B：四個獨立容器（官方 `docker-compose-distributed.yml` 的精簡版） |
| `verify.sql` | 兩種模式共用的驗證腳本 |
| `scale.sql` | 附加實驗：擴容之後 Actor 會怎麼分佈（只適用 distributed） |

兩份 compose 都精簡自官方檔案：拿掉 Prometheus、Grafana、Redpanda 與外掛的
`risingwave.toml`，記憶體調小到筆電跑得動，保留的是節點結構本身。

> **為什麼不直接 `wget` 官方那兩份？**
> 官方 compose 有 `volumes` 掛載 `./risingwave.toml`、`./prometheus.yaml`、
> `./dashboards` 等檔案。只抓一個 `.yml` 是跑不起來的，得把整個 `docker/`
> 目錄拉下來。文章裡的 `wget` 指令適合看內容，真的要跑請用這裡的版本。

## 環境需求

- Docker（OrbStack 或 Docker Desktop）
- `psql`
- 約 6 GB 可用記憶體

**一次只跑一種模式**，兩邊都用 4566。切換前先 `docker compose down -v`。

---

## 模式 A：standalone

```bash
cd standalone
docker compose up -d

# 等 healthy（約 20–40 秒，第一次要拉 image 會更久）
docker compose ps
```

### 步驟一：看看有幾個容器

```bash
docker compose ps --format '{{.Service}}'
```

```
minio-0
postgres-0
risingwave-standalone      ← RisingWave 只有這一個
```

### 步驟二：再看看容器裡有幾個 process

```bash
docker compose exec risingwave-standalone ps -eo pid,comm
```

```
    PID COMMAND
      1 risingwave            ← 就這一個
```

### 步驟三：但 RisingWave 說自己有四個節點

```bash
psql -h localhost -p 4566 -d dev -U root -f ../verify.sql
```

Part 1 的輸出：

```
 id |           type           |  host   | port |  state
----+--------------------------+---------+------+---------
  0 | WORKER_TYPE_META         | 0.0.0.0 | 5690 | RUNNING
  1 | WORKER_TYPE_COMPACTOR    | 0.0.0.0 | 6660 | RUNNING
  2 | WORKER_TYPE_FRONTEND     | 0.0.0.0 | 4566 | RUNNING
  3 | WORKER_TYPE_COMPUTE_NODE | 0.0.0.0 | 5688 | RUNNING
```

**四個 worker，host 全是 `0.0.0.0`，`started_at` 幾乎同一秒**——這就是 standalone
的指紋。它們是同一個 process 裡的四個執行緒，各自向 Meta 註冊了一份身份。
看日誌的執行緒名稱也看得出來：

```bash
docker compose logs risingwave-standalone | grep -o 'rw-standalone-[a-z]*' | sort -u
```

```
rw-standalone-compactor
rw-standalone-compute
rw-standalone-frontend
rw-standalone-meta
```

**所以「四個節點」這句話，在 standalone 模式下是邏輯上的、不是實體上的。**
你沒辦法單獨重啟 Compute、沒辦法只給 Compactor 加記憶體，
也看不到節點之間真實的 RPC 行為。

### 步驟四：坑 1 的第一現場

verify.sql 的 Part 2 會印出 RisingWave 看到的機器記憶體：

```
           type           | system_memory_gib
--------------------------+-------------------
 WORKER_TYPE_COMPUTE_NODE |              7.81
```

但 compose 裡我們只給了 3 GiB 的預算：

```bash
docker compose logs risingwave-standalone | grep -A8 'Memory outline'
```

```
> total_memory: 3.00 GiB
>     storage_memory: 860.00 MiB
>         block_cache_capacity: 258.00 MiB
>         meta_cache_capacity: 344.00 MiB
>         shared_buffer_capacity: 258.00 MiB
>     compute_memory: 1.26 GiB
>     reserved_memory: 921.60 MiB
```

**7.81 GiB 是它看到的機器，3.00 GiB 是它答應要用的量。**
這兩個數字是分開的——這個範例裡我們主動用 `--total-memory-bytes` 說清楚了，
所以是安全的。生產環境的坑在於：K8s 設了 4 GiB 的 memory limit，卻沒告訴
RisingWave，它就會照著「機器有多少」去撐 cache，然後被 kubelet 殺掉。
（下面 distributed 模式會示範對齊之後的樣子。）

### 收工

```bash
docker compose down -v
```

`-v` 一定要加，否則 MinIO 與 PostgreSQL 的 volume 會留著，下次啟動會撿到舊的
metadata。

---

## 模式 B：distributed

```bash
cd distributed
docker compose up -d
docker compose ps
```

### 步驟一：這次是四個容器

```bash
docker compose ps --format '{{.Service}}'
```

```
compactor-node
compute-node
frontend-node
meta-node          ← 四個節點，四個容器
minio-0
postgres-0
```

### 步驟二：同一支 SQL，不同的答案

```bash
psql -h localhost -p 4566 -d dev -U root -f ../verify.sql
```

```
 id |           type           |      host      | port |  state
----+--------------------------+----------------+------+---------
  0 | WORKER_TYPE_META         | meta-node      | 5690 | RUNNING
  1 | WORKER_TYPE_COMPUTE_NODE | 192.168.107.5  | 5688 | RUNNING
  2 | WORKER_TYPE_COMPACTOR    | compactor-node | 6660 | RUNNING
  3 | WORKER_TYPE_FRONTEND     | frontend-node  | 4566 | RUNNING
```

**host 各不相同**——這才是真的四個節點。現在你可以：

```bash
# 只重啟 Compute，Meta 與 Frontend 不受影響
docker compose restart compute-node

# 只看 Compactor 在幹嘛
docker compose logs -f compactor-node
```

### 步驟三：對齊過的記憶體長什麼樣

distributed 的 compose 給 `compute-node` 設了 `limits.memory: 4G`，
Part 2 這次會印出：

```
           type           | system_memory_gib
--------------------------+-------------------
 WORKER_TYPE_COMPUTE_NODE |               4.0    ← 不再是機器的 7.81
 WORKER_TYPE_COMPACTOR    |               2.0
```

RisingWave 讀得到 cgroup 的 limit，所以它知道自己被限制在 4 GiB；
而我們給的預算是 3 GiB，中間留了 1 GiB 給 cache 以外的用量。
**「容器 limit 4 GiB / RisingWave 預算 3 GiB」就是文章坑 1 要的那個對齊。**
把 `--total-memory-bytes` 拿掉或設得比 limit 大，就是 OOMKilled 的配方。

### 步驟四：狀態真的在物件儲存裡（坑 2 的檢查點）

verify.sql 跑完的 `FLUSH` 會觸發一次 Checkpoint。打開 MinIO Console：

- http://localhost:9400
- 帳密 `hummockadmin` / `hummockadmin`
- 進 `hummock001` bucket → `hummock_001/` → 底下的編號資料夾裡是一堆 `.data` 檔

也可以直接從容器看：

```bash
docker compose exec minio-0 sh -c 'ls /data/hummock001/hummock_001/*/'
```

```
/data/hummock001/hummock_001/112/:
4.data

/data/hummock001/hummock_001/119/:
10.data
...
```

這些就是 Hummock 的 SST 檔——你的 MV 狀態存在這裡，不在 Compute Node 的磁碟上。
**關鍵是寫入的時機**：`CREATE MATERIALIZED VIEW` 與 `INSERT` 的當下，資料還在
記憶體，是 `FLUSH` 觸發的 Checkpoint 才把它推進物件儲存。所以權限給不夠時，
建 MV 那一步不會報錯，要等到第一次 Checkpoint 才炸——生產環境上到 S3，
記得叢集起來後立刻手動 `FLUSH;` 一次，把權限問題提早逼出來。

### 步驟五：加一台 Compute Node（附加實驗）

```bash
docker compose up -d --scale compute-node=2
psql -h localhost -p 4566 -d dev -U root -f ../scale.sql
```

新節點確實加進來了：

```
 id |           type           |      host      | parallelism
----+--------------------------+----------------+-------------
  1 | WORKER_TYPE_COMPUTE_NODE | 192.168.107.5  |           4
  4 | WORKER_TYPE_COMPUTE_NODE | 192.168.107.8  |           4    ← 新的
```

但既有 MV 的 Actor 一個都沒搬：

```
 worker_id |     host      | actor_count
-----------+---------------+-------------
         1 | 192.168.107.5 |          16    ← 全部還在原本那台
```

擴容後**新建**的 MV 才會用到兩台：

```
 worker_id |     host      | actor_count
-----------+---------------+-------------
         1 | 192.168.107.5 |          24
         4 | 192.168.107.8 |           8    ← 新 MV 的 actor 落在這（兩邊的比例每次跑會不同）
```

要讓既有的 MV 也用到新節點，得明講：

```sql
ALTER MATERIALIZED VIEW mv_sales_by_city SET PARALLELISM = ADAPTIVE;
```

```
 worker_id |     host      | actor_count
-----------+---------------+-------------
         1 | 192.168.107.5 |          24
         4 | 192.168.107.8 |          16    ← 搬過去了
```

**這是自管部署很容易誤判的一件事**：擴容是兩個動作——「加機器」和
「讓既有作業用到新機器」。只做第一步，你會得到一台閒置的新機器，
而原本快 OOM 的那台完全沒有變輕。

### 收工

```bash
docker compose down -v
```

---

## 對照總表

| | standalone | distributed |
|---|---|---|
| RisingWave 容器數 | 1 | 4 |
| `rw_worker_nodes` 的 host | 全部 `0.0.0.0` | 各自不同 |
| 單獨重啟某個角色 | 做不到 | `docker compose restart compute-node` |
| 單獨配資源 | 做不到 | 每個節點各自設 limit |
| 節點間 RPC | 同 process 內呼叫 | 真的走網路 |
| 適合用來 | 學語法、跑 Toy Case、CI | 觀察節點行為、預演生產拓撲 |
| 對應生產部署 | —— | Kubernetes + Operator |

**選哪個**：只是要跑 SQL 就用 standalone，快又省資源。
要理解「哪個節點該給多少資源」「Compactor 到底在忙什麼」「擴容會發生什麼事」，
就得用 distributed——這些問題在 standalone 裡是看不見的。

---

## 快速排錯

| 症狀 | 原因 | 處理 |
|---|---|---|
| `port is already allocated` | 4566 被另一個範例佔住 | 先把別的 stack `docker compose down -v` |
| `psql: could not connect` | 容器還沒 healthy | 等 `docker compose ps` 顯示 healthy 再連 |
| `\d rw_catalog.rw_actors` 報 collate 錯誤 | psql 15+ 的 `\d` 用到 RisingWave 未支援的 collation | 改用 `SELECT * FROM rw_catalog.rw_actors LIMIT 1;` 看欄位 |
| distributed 的 compute-node 一直重啟 | 記憶體不夠（compose 要 4G limit） | 調小 `--total-memory-bytes` 與 `limits.memory`，或關掉其他容器 |
| 切換模式後 metadata 錯亂 | 上次 `down` 沒加 `-v` | `docker compose down -v` 後重來 |
| `--scale compute-node=2` 只看到一個 worker | 新容器還在註冊 | 等 5–10 秒再查 `rw_worker_nodes` |

## 驗證環境

本範例在以下環境實際跑過：macOS（Apple Silicon, arm64）、Docker 28.3.3、
RisingWave `v3.0.3`、psql 18.6。文中的輸出都是實際跑出來的結果，
worker id 與容器 IP 會因環境而異。

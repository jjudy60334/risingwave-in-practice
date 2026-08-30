# RisingWave in Practice

《**RisingWave 不踩坑實戰：30 天搞懂串流數據庫**》的可跑範例。
資料夾依天數排列，方便對照文章邊讀邊跑；每個都能獨立執行。

## 範例一覽

| 資料夾 | 搭配文章 | 在問什麼 |
|---|---|---|
| [`day04-mv-across-databases/`](./day04-mv-across-databases/) | Day 04 各家 MV 大不同 | 刪掉來源那筆，各家的 MV 會不會跟著變？ |
| [`day06-delete-propagation/`](./day06-delete-propagation/) | Day 06 資料品質基礎 | MV 的 DELETE 事件怎麼傳到下游 Table？ |

> 維護備註：大綱調整時，資料夾用 `git mv` 改天數前綴、同步更新上表即可。
> 主題後綴（`-mv-across-databases`）刻意保留，讓改號不影響內容辨識。

## 環境需求

- Docker（OrbStack 或 Docker Desktop）
- Apple Silicon 可直接跑，三家 image 都有原生 arm64
- **不要**對任何服務指定 `platform: linux/amd64`，強制 x86 模擬會讓
  StarRocks 的 C++ 元件 crash

各範例的詳細跑法見各自的 README。

## 授權

MIT

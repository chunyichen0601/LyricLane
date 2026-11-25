---
name: lyrics-dev
description: LyricLane 的歌詞與同步引擎開發流程：Spotify 播放位置（App Remote 直連＋Web API）、本機計時換句、LRCLIB 歌詞搜尋／LRC 解析／快取、簡轉繁、時間微調、播放佇列預抓。只要改到 SyncEngine、SpotifyRemote、SpotifyClient、SpotifyAuth、LyricsProvider，或在處理「歌詞不同步、慢半拍、抓錯歌詞、找不到歌詞、跳歌後錯亂」這類問題，就先讀這份。
---

# 歌詞開發（LyricLane）

## 資料流

```
Spotify App ──App Remote（直連，事件推送）──┐
Spotify Web API（/me/player/currently-playing）┴─▶ SyncEngine.ingest()
                                                     │ 錨點：anchorProgress @ anchorDate
                                                     ▼
                         LyricsProvider（LRCLIB → LRC 解析 → 快取）
                                                     ▼
                     reschedule()：DispatchSource 計時器在下一句觸發
                       ├─ App 畫面（currentIndex）
                       ├─ 即時動態（activityIndex，提早 0.5 秒）
                       └─ CarPlay 小工具（SharedStore 整首時間表）
```

## 播放位置：規則

- **直連優先**（`SpotifyRemote`，`SPTAppRemote`）：本機 IPC、事件即時、位置可信（`trusted: true`），誤差 > 40 ms 就重設錨點。
  - 需要登入時有 `app-remote-control` scope，且 Spotify 開發者後台勾 iOS、填 Bundle ID。
  - 直連在 **Spotify 暫停約 30 秒後會自己斷**，這是 SDK 行為，不是 bug；`pollOnce` 會自動重連／退回 Web API。
  - 15 秒沒收到狀態就視為卡住，斷開重連（`isHealthy`）。
  - **所有 delegate 回呼都要確認是目前這條連線**（`remote === appRemote`），舊連線晚到的通知不能動新連線的狀態。
- **Web API 退路**（`SpotifyClient`）：`progress_ms` 會落後 0.5～1.5 秒，`timestamp` 欄位不可靠 → 用請求來回的**中點**當取樣時間。規則：只接受「往前」修正（> 0.1 秒），落後 > 2 秒視為使用者拖回，連續 3 次落後 > 0.6 秒才相信。
  - 直連剛換歌後 10 秒內，**忽略 Web API 回報的上一首**（它還沒更新）。
  - 歌曲開頭每秒取樣；快結束時在剩餘時間 +0.3 秒再問一次，換歌才不慢。
  - 429 要遵守 `Retry-After`。
- 不要用 `MPNowPlayingInfoCenter` 讀 Spotify，第三方讀不到。

## 換句計時

- 位置 = `anchorProgress + (now − anchorDate)`（播放中）。不要每句去問 Spotify。
- `reschedule()` 用 `DispatchSource`（`.strict`、2 ms leeway）在**下一個邊界**叫醒：畫面的下一句或即時動態的下一句（提早 `activityLead`），取早的。
- 計時器晚 > 1.5 秒會記「App 被系統暫停過」，保留這個診斷。
- 使用者微調 `AppSettings.offsetMs`（正值 = 提早，預設 +150 ms，範圍 ±1500）。所有位置計算都要加上它：`position() + offsetMs / 1000`。小工具用 `SharedStore.NowPlaying.offset + lead`。

## 歌詞：搜尋與解析（`App/LyricsProvider.swift`）

- 來源：LRCLIB（免費、免金鑰）。User-Agent 不要放個資。
- 順序：`/api/get` 精準比對（歌名＋歌手＋專輯＋長度）→ `/api/search` 用「歌名寫法 × 歌手寫法」排列組合搜尋 → 最後只用歌名搜。每首最多 16 次請求（`requestBudget`）。
- **繁簡互查＋歌手別名**（`App/LyricsMatcher.swift`）：歌名試原樣／繁體／簡體／標點換空白；歌手試原名、別名表（例：Jay Chou ↔ 周杰倫）、繁簡版本。別名表用繁體寫，比對用 `key()`（小寫＋轉簡體＋去標點），所以繁簡都認得。新增別名就在 `artistGroups` 加一行。
- 挑結果（`pick`）：歌名相同 > 歌手相同（含別名）> 長度最接近，長度差 < 8 秒；只用歌名搜的結果要「歌名對＋（歌手對或長度差 < 3 秒）」才採用，避免抓到同名歌。
- 換寫法才找到時，診斷紀錄會記「歌詞：換寫法才找到」。
- `clean()` 去掉「 - Remastered」「(feat. …)」等後綴。
- LRC 解析（`LRCParser.parse`）：支援 `[offset:]`、一行多個時間標、去掉逐字 `<mm:ss.xx>`；排序後**同時間的多行（原文＋翻譯）合併成一句**。
- 快取：記憶體＋`Caches/lyrics/<trackURI>.json`。**只快取找到的**；網路失敗或被取消（跳歌）不能記成「找不到」。`forget()` 給重新同步用。
- **歌詞一律顯示繁體**：`LyricsMatcher.toTraditional`（ICU `Hans-Hant`，逐字轉換，不會換成台灣用語），在 `rebuildLines()` 做（顯示時轉，快取存原文）。設定裡已沒有開關。
- 防抖：停在同一首 0.35 秒才抓歌詞，連續跳歌時中間的歌不送請求。

### 預抓（`prefetchUpcoming`）

- 目前這首歌詞載入後等 5 秒，呼叫 `/v1/me/player/queue`，抓接下來 `prefetchCount`（5）首存進快取。換歌時歌詞秒出、沒訊號也有。
- 需要 `user-read-playback-state` scope（已在 `SpotifyAuth.scopes`）。Podcast（沒有歌手）跳過。
- 下一首換歌時取消重來；已快取的不會重抓（`hasCached`）。

### 想提升命中率可以參考（還沒做）

- DriveVerse：版本詞過濾（live／伴奏／翻唱／remaster），長度差 3 秒內，酷狗／網易雲當中文歌補充來源（注意授權，只限自用）。
- Spotify 公開 API **沒有歌詞**；它 App 內的歌詞是 Musixmatch 的非公開介面，不要用。

## 開發與驗證流程

1. 開分支改程式；同步邏輯的關鍵事件加 `DiagLog.log(...)`（換歌、對時誤差、找不到歌詞、預抓結果都已有）。
2. 推分支開 PR → GitHub Actions 用雲端 Xcode 編譯（不發佈）。環境裡 gh GraphQL 不能用，用 `gh api repos/chunyichen0601/LyricLane/...`。
3. 合併 main → Actions 發 Release → SideStore 更新。
4. 請使用者實測：⚙️ › 進階與診斷 可看「上次對時誤差」「來回時間」「來源（直連／網路）」；有問題就匯出診斷紀錄。
   - 歌詞整體慢／快 → 先看來源是不是直連，再調 ⚙️ 歌詞時間。
   - 跳歌後錯亂 → 紀錄裡找「換歌：」「忽略網路回報的舊資料」「直連：中斷」。
   - 抓錯歌詞 → ↻ 重新同步會清掉這首的快取重抓。

## 不要做

- 不要在每一句都打網路（Spotify 或 LRCLIB）。
- 不要把 Web API 的落後資料當成真的落後而往回調（只有連續 3 次或 > 2 秒才算）。
- 不要把 Spotify Client Secret 寫進程式；登入是 PKCE，只需要 Client ID（使用者自己填）。

---
name: carplay-dev
description: LyricLane 的 CarPlay／動態島／即時動態（Live Activity）與 CarPlay 小工具（WidgetKit）開發流程與規則。只要改到 Widget/、LiveActivityManager、KeepAlive、LocationKeepAlive、SyncEngine 裡跟即時動態或小工具有關的部分，或在處理「CarPlay 歌詞卡住、不更新、跟不上、疊字、消失」這類問題，就先讀這份。
---

# CarPlay 開發模式（LyricLane）

## 先搞懂：歌詞是怎麼上 CarPlay 的

LyricLane **沒有 CarPlay App 畫面**（那要 Apple 核准的 `com.apple.developer.carplay-audio`，免費 Apple ID／SideStore 拿不到）。CarPlay 上的歌詞只有兩條路：

| 路徑 | 檔案 | 怎麼換句 | 可靠度 |
|---|---|---|---|
| 即時動態（Live Activity，iOS 26 會投射到 CarPlay） | `App/LiveActivityManager.swift`、`Widget/LyricsLiveActivity.swift` | App 在背景每句呼叫 `activity.update` | **主力**，前提是 App 在背景活著且 iOS 允許更新 |
| CarPlay 小工具（WidgetKit `.systemSmall`） | `Widget/CarLyricsWidget.swift`、`Shared/SharedStore.swift` | App 每首歌交一次整首時間表，一句一個 timeline entry，系統自己切 | 盡力而為：Apple 設計上 entry 要隔約 5 分鐘，CarPlay 切換又會晚 |

## 鐵則（違反就會「播兩句就卡住」）

1. **背景不能只靠音訊。** iOS 會擋「背景只在播音訊」的 App 更新即時動態（liveactivitiesd：`Process is only playing background media so is forbidden to update activity`）。一定要同時有 `LocationKeepAlive`（3 km 低精度、`pausesLocationUpdatesAutomatically = false`、`.automotiveNavigation`）。`UIBackgroundModes` 必須有 `location`。
2. **使用者要開「更頻繁更新」**（設定 › LyricLane › 即時動態）。沒開背景約 30 秒就停。`ActivityAuthorizationInfo().frequentPushesEnabled` 檢查，主畫面有 `FrequentUpdatesBanner` 提醒，不要拿掉。
3. **App 在背景時不能開新的即時動態**（`Activity.request` 會失敗；只有 `LiveActivityIntent` 的 `perform()` 例外）。所以：整趟只用同一個 activity，換歌只 update；重新同步用 `forceRefresh`，**絕對不要 end 再 request**。
4. **即時動態不要動畫。** CarPlay 換句動畫中會把新舊兩句疊著畫（Apple 論壇 thread 804483）。保持 `.contentTransition(.identity)` 和 `.transaction { $0.animation = nil }`。
5. **換句要提早送。** `activity.update` 回傳 ≠ 已顯示。`SyncEngine.activityLead = 0.5` 秒；小工具 `carWidgetLead = 0.5` 秒。改時間邏輯時保留這兩個提早量。
6. **更新管線不能被一次卡住拖死。** `LiveActivityManager` 是「只送最新」的序列迴圈，加 1.5 秒逾時與 generation 計數。不要改回單純的 `sending` 旗標。
7. **ContentState 要小（上限 4 KB，含 attributes）。** 不要塞整首歌詞或大圖；長字串截斷。
8. **staleDate** = 下一句時間 + 10 秒（`staleDateForCurrentLine()`），暫停時 nil。App 死掉時畫面會很快顯示「已停止」。
9. **CarPlay 版面走 `.small` family**：`.supplementalActivityFamilies([.small, .medium])` + `@Environment(\.activityFamily)`。CarPlay 上按鈕不能按，只放最重要的資訊；字放不下用 `minimumScaleFactor`，不要截斷本句。
10. **小工具：** 不要用 `.blur` 等昂貴效果（每個 entry 都要預先算圖）；同首歌的 reload 有 10 秒節流；換歌、暫停、拖進度才 reload。App 有音訊／導航工作階段時 reload 不算預算，但仍不要狂刷。

## 開發流程（沒有 Mac）

1. **改程式** → 開分支（不要直接推 main）。
2. **推分支開 PR** → GitHub Actions（`.github/workflows/build.yml`，macOS runner + Xcode）會對 PR 編譯，但**不會發佈**。這就是「Xcode 檢查」。等它綠燈：
   ```bash
   gh run list -R chunyichen0601/LyricLane -b <分支> -L 1
   ```
   （這個環境 gh 的 GraphQL 不能用，PR／合併都用 `gh api repos/...` REST。）
3. **合併到 main** → Actions 編譯並發 Release＋`source.json` → 使用者在 SideStore 的 My Apps 更新。
4. **實機驗證只能靠使用者開車測**。請他卡住時按一下 ↻（紀錄裡留記號），回家後 ⚙️ › 進階與診斷 › 匯出診斷紀錄。

## 看診斷紀錄（`Shared/DiagLog.swift`）

| 紀錄裡看到 | 代表 | 方向 |
|---|---|---|
| 「第 i/N 句」持續在記，但畫面沒動 | App 活著，iOS 沒顯示 | 看下一列的序號 |
| 每分鐘摘要：送出 #N 遠大於 iOS 套用 #M | iOS 拒絕／節流更新 | 檢查定位保活、更頻繁更新 |
| iOS 套用 #M 正常，CarPlay 畫出 #K 停住 | CarPlay 沒重畫（不在畫面上時本來就不畫） | 確認當時 CarPlay 有顯示即時動態 |
| 紀錄中間一大段空白、「換句計時器晚了 X 秒」 | App 被系統暫停 | 背景保活失效：看「背景音訊被打斷」「定位保活」紀錄 |
| 開車途中出現「===== App 啟動」 | App 被系統結束後重啟 | 記憶體、`記憶體不足警告` |
| 「即時動態：狀態變成 dismissed/ended」 | 被滑掉或到 8 小時上限 | 下次前景會自動重開（`wantsActivity`） |

新增功能時，**關鍵事件一定要加 `DiagLog.log(...)`**（中文、一行、可讀），因為沒有 Xcode console。

## 做不到的事（不要再花時間）

- APNs／push-to-start／broadcast 推播更新：需要付費開發者帳號＋伺服器。
- CarPlay template App 畫面：需要 Apple 核准 entitlement。
- `_ClockHandRotationEffect` 之類私有 API 讓小工具自己動：iOS 26.1 SDK 起失效，CarPlay 上本來就停。
- 讀 Spotify 的 Now Playing（`MPNowPlayingInfoCenter`）：第三方 App 讀不到。

## 已知環境問題

- iOS 26.0.x：CarPlay 即時動態舊字不清掉、疊字 → 要求 26.1 以上。
- iOS 26.2 部分車機放三個小工具時，即時動態可能不顯示。
- SideStore 會改 App Group 名稱（寫在 Info.plist 的 `ALTAppGroups`），`SharedStore.groupID` 已處理；App 與小工具抓不到共用空間時，請使用者用 SideStore 重裝。

## 參考實作（開源，做法相同）

- DriveVerse／LyricsIsland：<https://github.com/baugette-coder/LyricsIsland-driveverse>（定位保活、提早送、更新節流）
- Lyrics Dash：<https://github.com/ispa21/car-lyrics>（序號追蹤送出／套用／畫出、CarPlay 小工具提早量、狀態頁）
- lyricar：<https://github.com/noluyorAbi/lyricar>（CarPlay template，需 entitlement）

# LyricLane — CarPlay 歌詞

把 Spotify 正在播的歌詞即時顯示在 **CarPlay、動態島、鎖定畫面**（用 iOS 26 的即時動態）。

- 需求：iPhone，**iOS 26 以上**才會在 CarPlay 顯示（iOS 18 起動態島、鎖定畫面可用）
- 歌詞來源：[LRCLIB](https://lrclib.net)（免費同步歌詞）
- 不需要 Mac：用 GitHub Actions 的雲端 Mac 編譯，再用 SideStore 裝到手機並自動續簽

## 👉 安裝請看 [懶人包.md](懶人包.md)

下面是舊版（Sideloadly 手動安裝）的說明，僅供參考。

---

## 一、申請 Spotify Client ID（5 分鐘）

1. 到 <https://developer.spotify.com/dashboard> 用你的 Spotify 帳號登入 → **Create app**
2. 填寫：
   - App name / description：隨便填
   - **Redirect URI：`dynlyrics://callback`**（一字不差，按 Add）
   - 勾選 **Web API**
3. 建立後進入 App → **Settings**，複製 **Client ID**
4. 在 **User Management** 把你自己的 Spotify 帳號 email 加進去（開發模式只有名單內的人能登入）

## 二、用 GitHub 雲端編譯出 .ipa

1. 註冊 / 登入 GitHub，建立一個新的 repository（建議 **Public**：Actions 免費不限分鐘；Private 每月也有免費額度，夠用）
2. 把這個資料夾的所有檔案上傳到 repo（建議用 [GitHub Desktop](https://desktop.github.com)，網頁拖曳上傳可能會漏掉 `.github` 這個隱藏資料夾）
3. 上傳後到 repo 的 **Actions** 分頁，會自動開始跑「Build IPA」，約 3–6 分鐘
4. 跑完（綠色勾勾）點進去，最下方 **Artifacts** 下載 `DynLyrics-ipa`，解壓縮得到 `DynLyrics.ipa`
5. 如果是紅色 ✗：點進失敗的步驟，把錯誤訊息貼給 Claude 修正

## 三、用 Sideloadly 安裝到 iPhone（Windows）

1. 安裝 **iTunes**（請用 Apple 官網版，不要用 Microsoft Store 版）
2. 安裝 [Sideloadly](https://sideloadly.io)
3. iPhone 用 USB 接上電腦，手機上按「信任這部電腦」
4. 把 `DynLyrics.ipa` 拖進 Sideloadly，輸入 Apple ID，按 Start
   - ⚠️ 會需要 Apple ID 密碼。建議另外開一個**次要 Apple ID** 專門拿來簽 App
5. iPhone 上：
   - **設定 > 隱私權與安全性 > 開發者模式** → 開啟（會重新開機）
   - **設定 > 一般 > VPN 與裝置管理** → 信任你的 Apple ID
6. 免費 Apple ID 簽的 App **7 天後會失效**，到時用 Sideloadly 再裝一次即可（資料不會掉）。付費開發者帳號（US$99/年）可以用一年。

## 四、使用

1. 打開「動態歌詞」→ 最下方貼上 Client ID → **登入 Spotify**
2. 用 Spotify 播歌，App 會自動抓歌詞並啟動即時動態
3. 上車接 CarPlay，即時動態會出現在 CarPlay 畫面上
   - 若沒出現：檢查 **設定 > 動態歌詞 > 即時動態** 是否開啟，以及 **設定 > 一般 > CarPlay > 你的車** 裡的即時動態相關選項
4. **歌詞提早**滑桿：歌詞比歌聲慢就往右、比歌聲快就往左。無線 CarPlay / 藍牙音訊有延遲，一般調到 −100 ~ −300 ms 左右會剛好，找到後就不用再動

### 小提醒

- iOS 規定即時動態只能在 App 開著的時候啟動，而且一次最長約 8 小時 → **上車前打開 App 一次**就好
- App 會在背景播放無聲音訊來保持執行（不會打斷 Spotify），這是歌詞能準時換行的關鍵
- 找不到歌詞代表 LRCLIB 沒收錄這首歌；歌詞會快取在手機上，第二次播放不需要網路

---

## 原理（為什麼不會延遲）

| 延遲來源 | 做法 |
|---|---|
| Spotify API 只能輪詢 | 每 ~3 秒拿一次進度，只用來**校正**；實際計時在手機本機用「錨點＋經過時間」推算 |
| 網路延遲 | 量測每次請求的來回時間，取中點當作進度的時間點；小誤差平滑修正、大誤差（拖進度、暫停）立即重設 |
| 換歌 | 在歌曲剩餘時間到的瞬間再問一次 Spotify，換歌幾乎同步 |
| 換句時機 | 用精準計時器在**下一句的時間點**觸發，誤差約 5 ms |
| 即時動態更新 | 在本機直接 `activity.update()`，不走推播，沒有推播次數限制或網路延遲 |
| 渲染與音訊延遲 | 可調整的提早量（預設 +150 ms） |

## 檔案

```
project.yml                     XcodeGen 專案設定（雲端自動產生 .xcodeproj）
App/SyncEngine.swift            同步引擎（核心）
App/SpotifyAuth.swift           Spotify PKCE 登入
App/SpotifyClient.swift         取得播放進度
App/LyricsProvider.swift        LRCLIB 歌詞＋LRC 解析＋快取
App/LiveActivityManager.swift   即時動態
App/KeepAlive.swift             背景執行
App/ContentView.swift           主畫面（含 CarPlay 字級預覽）
App/LyricsIntents.swift         Siri／捷徑／CarPlay 自動化
Widget/LyricsLiveActivity.swift 即時動態畫面（CarPlay／動態島／鎖定畫面）
.github/workflows/build.yml     雲端編譯
```

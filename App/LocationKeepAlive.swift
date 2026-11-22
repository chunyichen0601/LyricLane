import CoreLocation

/// 用「低精度定位」讓 App 在背景持續執行，跟導航 App 一樣。
///
/// 為什麼不能只靠無聲音訊：iOS 會擋掉「背景只在播音訊」的 App 更新即時動態
/// （系統日誌：Process is only playing background media so is forbidden to update activity）。
/// 有定位工作階段的 App 才被允許在背景更新即時動態——導航 App 就是這樣做的。
///
/// - 精度設 3 公里：用基地台／Wi-Fi 就夠，不開 GPS，幾乎不耗電
/// - 位置資料直接丟掉，不儲存、不上傳；需要的只是「定位工作階段存在」這件事
/// - 做法參考開源專案 DriveVerse、Lyrics Dash（都是 CarPlay 歌詞 App）
/// - 這種用法上不了 App Store，SideStore 自己裝沒問題
@MainActor
final class LocationKeepAlive: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = LocationKeepAlive()

    private let manager = CLLocationManager()
    private var wanted = false
    private(set) var isUpdating = false

    /// 給設定頁顯示用
    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 1_000
        // 一定要關：不然停紅燈、塞車時 iOS 會自動暫停定位，App 就跟著被暫停
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        guard AppSettings.shared.useLocationKeepAlive else { return }
        wanted = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization() // 允許後在 delegate 裡開始
        case .denied, .restricted:
            DiagLog.log("定位保活：沒有定位權限，只靠無聲音訊（即時動態在背景可能被系統擋掉）")
        default:
            begin()
        }
    }

    func stop() {
        wanted = false
        guard isUpdating else { return }
        isUpdating = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        DiagLog.log("定位保活：關閉")
    }

    /// 看門狗：應該開著卻沒開（例如權限剛被改回來）就再開一次
    func ensureRunning() {
        guard wanted, !isUpdating else { return }
        start()
    }

    private func begin() {
        guard wanted, !isUpdating else { return }
        isUpdating = true
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        DiagLog.log("定位保活：開啟（權限 \(Self.describe(manager.authorizationStatus))）")
        // 「使用 App 期間」只在 App 從前景開始時有效；
        // 「永遠」才能讓 CarPlay 自動化在背景直接啟動。
        if manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DiagLog.log("定位權限：\(Self.describe(manager.authorizationStatus))")
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            begin()
        case .denied, .restricted:
            if isUpdating {
                isUpdating = false
                manager.stopUpdatingLocation()
            }
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 位置不需要，直接丟掉
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // .locationUnknown 只是暫時沒訊號；只有被拒絕才要處理
        if (error as? CLError)?.code == .denied {
            DiagLog.log("定位保活：權限被拒絕")
            isUpdating = false
        }
    }

    static func describe(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .authorizedAlways: "永遠"
        case .authorizedWhenInUse: "使用 App 期間"
        case .denied: "不允許"
        case .restricted: "受限制"
        case .notDetermined: "尚未詢問"
        @unknown default: "未知"
        }
    }
}

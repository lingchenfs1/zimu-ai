import Foundation

/// 在线更新的策略：何时自动检查、是否提示、允许从哪里下载（决策 D21）
public enum UpdatePolicy {
    /// 自动检查间隔
    public static let autoCheckInterval: TimeInterval = 86_400
    /// 启动后多久做第一次自动检查
    public static let launchDelay: TimeInterval = 10
    /// 更新包大小上限
    public static let maximumAssetSize: Int64 = 512 * 1024 * 1024
    /// 限流时最多暂停自动检查多久：GitHub 未登录的限流 1 小时内就会重置，
    /// 更远的时间只可能来自异常的响应头、不准的服务器时钟或被调回过去的本机时钟
    public static let maximumRateLimitWait: TimeInterval = 3600

    /// 现在是否应该自动检查：已开启、不在限流期内、距上次成功检查已满间隔
    public static func isAutoCheckDue(
        now: Date,
        lastSuccessfulCheck: Date?,
        rateLimitedUntil: Date?,
        enabled: Bool,
        interval: TimeInterval = autoCheckInterval
    ) -> Bool {
        guard enabled else { return false }
        // 限流结束时间远超上限时不再理会（留 1 分钟余量）
        if let until = rateLimitedUntil, now < until, until.timeIntervalSince(now) <= maximumRateLimitWait + 60 { return false }
        guard let last = lastSuccessfulCheck else { return true }
        // 时钟被调回过去时也要检查
        return now.timeIntervalSince(last) >= interval || now < last
    }

    /// 是否提示这个新版本：用户跳过的版本只在手动检查时显示
    public static func shouldNotify(_ info: UpdateInfo, skippedVersion: String, manual: Bool) -> Bool {
        manual || SemanticVersion(skippedVersion) != info.version
    }

    /// 下载地址（包括重定向后的地址）是否可信：只允许 https、默认端口、没有用户信息，
    /// 并且是发布新版本的仓库的下载路径或 GitHub 的发布文件存储主机
    public static func isAllowedDownloadURL(_ url: URL, repository: String) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased()
        else { return false }
        switch host {
        case "github.com":
            return url.path.lowercased().hasPrefix("/\(repository.lowercased())/releases/download/")
        case "release-assets.githubusercontent.com", "objects.githubusercontent.com":
            return true
        default:
            return false
        }
    }
}

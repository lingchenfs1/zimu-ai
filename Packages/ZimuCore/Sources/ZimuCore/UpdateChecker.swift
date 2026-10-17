import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// GitHub Release（只取在线更新需要的字段）
public struct GitHubRelease: Decodable, Sendable, Equatable {
    public var tagName: String
    public var name: String?
    public var body: String?
    public var htmlURL: URL
    public var publishedAt: Date?
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case draft
        case prerelease
        case assets
    }
}

public struct GitHubReleaseAsset: Decodable, Sendable, Equatable {
    public var name: String
    public var size: Int64
    public var state: String
    public var browserDownloadURL: URL
    /// 上传时由 GitHub 计算的摘要，例如 "sha256:…"；旧文件可能没有
    public var digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case size
        case state
        case browserDownloadURL = "browser_download_url"
        case digest
    }
}

/// 在线更新的配置（决策 D21）
public struct UpdateConfiguration: Sendable, Equatable {
    /// 公开发布仓库，形如 "owner/repo"
    public var repository: String
    /// 安装包文件名前缀：资产名为 "<前缀><版本><后缀>"
    public var assetPrefix: String
    /// 软件内更新用的资产后缀（zip）
    public var updateAssetSuffix: String
    /// 手动安装用的资产后缀（dmg）
    public var installerAssetSuffix: String

    public init(
        repository: String,
        assetPrefix: String = "ZimuAI-",
        updateAssetSuffix: String = ".zip",
        installerAssetSuffix: String = ".dmg"
    ) {
        self.repository = repository
        self.assetPrefix = assetPrefix
        self.updateAssetSuffix = updateAssetSuffix
        self.installerAssetSuffix = installerAssetSuffix
    }

    /// 仓库名是否合法（防止拼出意外的 URL）
    public var isValidRepository: Bool {
        repository.range(of: #"^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    public var releasesPage: URL? {
        URL(string: "https://github.com/\(repository)/releases")
    }
}

/// 软件内更新要下载的文件
public struct UpdateAsset: Sendable, Equatable {
    public var name: String
    public var url: URL
    public var size: Int64
    /// 小写十六进制 SHA-256
    public var sha256: String

    public init(name: String, url: URL, size: Int64, sha256: String) {
        self.name = name
        self.url = url
        self.size = size
        self.sha256 = sha256
    }
}

/// 可用的新版本
public struct UpdateInfo: Sendable, Equatable {
    public var version: SemanticVersion
    /// 去掉 "v" 的标签，与新版本的 CFBundleShortVersionString 一致
    public var versionString: String
    public var tagName: String
    public var title: String
    /// 更新说明（Markdown）
    public var notes: String
    public var releasePage: URL
    public var publishedAt: Date?
    /// 软件内更新用的 zip；为 nil 时只能手动安装
    public var asset: UpdateAsset?
    /// 手动安装用的 DMG
    public var installerURL: URL?
    /// 不能软件内更新的原因
    public var manualOnlyReason: String?

    public init(
        version: SemanticVersion,
        versionString: String,
        tagName: String,
        title: String,
        notes: String,
        releasePage: URL,
        publishedAt: Date?,
        asset: UpdateAsset?,
        installerURL: URL?,
        manualOnlyReason: String?
    ) {
        self.version = version
        self.versionString = versionString
        self.tagName = tagName
        self.title = title
        self.notes = notes
        self.releasePage = releasePage
        self.publishedAt = publishedAt
        self.asset = asset
        self.installerURL = installerURL
        self.manualOnlyReason = manualOnlyReason
    }
}

public enum UpdateCheckOutcome: Sendable, Equatable {
    /// 已是最新；latest 为发布的最高版本（没有发布时为 nil）
    case upToDate(latest: SemanticVersion?)
    case available(UpdateInfo)
}

public enum UpdateCheckError: Error, LocalizedError, Equatable {
    /// GitHub 限流（未登录每个 IP 每小时 60 次）
    case rateLimited(until: Date?)
    case noReleases
    case http(Int)
    case invalidResponse
    case invalidRepository(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .rateLimited(let until):
            if let until {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                return "检查更新太频繁，GitHub 暂时拒绝了请求，请在 \(formatter.string(from: until)) 之后再试"
            }
            return "检查更新太频繁，GitHub 暂时拒绝了请求，请稍后再试"
        case .noReleases:
            return "还没有找到发布的版本"
        case .http(let status):
            return "检查更新失败（HTTP \(status)）"
        case .invalidResponse:
            return "无法解析 GitHub 返回的版本信息"
        case .invalidRepository(let repository):
            return "更新源设置无效：\(repository)"
        case .network(let message):
            return "无法连接 GitHub：\(message)"
        }
    }
}

/// 从公开发布仓库检查新版本（决策 D21）
public struct UpdateChecker: Sendable {
    public var configuration: UpdateConfiguration
    public var currentVersion: SemanticVersion
    public var userAgent: String
    private let client: any HTTPClient

    public init(configuration: UpdateConfiguration, currentVersion: SemanticVersion, userAgent: String, client: any HTTPClient) {
        self.configuration = configuration
        self.currentVersion = currentVersion
        self.userAgent = userAgent
        self.client = client
    }

    public func makeRequest() throws -> URLRequest {
        guard configuration.isValidRepository,
              let url = URL(string: "https://api.github.com/repos/\(configuration.repository)/releases?per_page=10")
        else { throw UpdateCheckError.invalidRepository(configuration.repository) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    public func check(now: Date = Date()) async throws -> UpdateCheckOutcome {
        let request = try makeRequest()
        let data: Data
        let info: HTTPResponseInfo
        do {
            (data, info) = try await client.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }
        if let error = Self.error(for: info, now: now) {
            throw error
        }
        let releases: [GitHubRelease]
        do {
            releases = try Self.decoder.decode([GitHubRelease].self, from: data)
        } catch {
            throw UpdateCheckError.invalidResponse
        }
        return try Self.evaluate(releases: releases, currentVersion: currentVersion, configuration: configuration)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 把非 2xx 响应转成错误；限流时根据 x-ratelimit-reset / retry-after 给出可再次检查的时间，
    /// 最多到 now + UpdatePolicy.maximumRateLimitWait（异常的响应头或不准的服务器时钟不能让自动检查停太久）
    static func error(for info: HTTPResponseInfo, now: Date) -> UpdateCheckError? {
        guard !info.isSuccess else { return nil }
        switch info.statusCode {
        case 403, 429:
            let latest = now.addingTimeInterval(UpdatePolicy.maximumRateLimitWait)
            // 只接受有限的非负秒数（TimeInterval.init 也会解析出 inf、nan 和负数）
            if let retryAfter = info.header("retry-after").flatMap(TimeInterval.init), retryAfter.isFinite, retryAfter >= 0 {
                return .rateLimited(until: min(now.addingTimeInterval(retryAfter), latest))
            }
            if info.header("x-ratelimit-remaining") == "0" {
                guard let seconds = info.header("x-ratelimit-reset").flatMap(TimeInterval.init), seconds.isFinite else {
                    return .rateLimited(until: nil)
                }
                // 重置时间按服务器时钟给出；已经过去（本机时钟偏快）时不知道还要等多久
                let reset = Date(timeIntervalSince1970: seconds)
                return .rateLimited(until: reset > now ? min(reset, latest) : nil)
            }
            return info.statusCode == 429 ? .rateLimited(until: nil) : .http(403)
        case 404:
            return .noReleases
        default:
            return .http(info.statusCode)
        }
    }

    /// 从 Release 列表中取最高的正式版本，判断是否比当前版本新，并选出更新用的文件
    public static func evaluate(
        releases: [GitHubRelease],
        currentVersion: SemanticVersion,
        configuration: UpdateConfiguration
    ) throws -> UpdateCheckOutcome {
        let candidates = releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release -> (SemanticVersion, GitHubRelease)? in
                guard let version = SemanticVersion(release.tagName), !version.isPrerelease else { return nil }
                return (version, release)
            }
        guard let (version, release) = candidates.max(by: { $0.0 < $1.0 }) else {
            if releases.isEmpty { throw UpdateCheckError.noReleases }
            return .upToDate(latest: nil)
        }
        guard currentVersion < version else {
            return .upToDate(latest: version)
        }

        let versionString = Self.versionString(fromTag: release.tagName)
        let updateName = configuration.assetPrefix + versionString + configuration.updateAssetSuffix
        let installerName = configuration.assetPrefix + versionString + configuration.installerAssetSuffix
        let installer = release.assets.first { $0.name == installerName && $0.state == "uploaded" }

        var asset: UpdateAsset?
        var reason: String?
        if let candidate = release.assets.first(where: { $0.name == updateName }) {
            if candidate.state != "uploaded" {
                reason = "安装包还在上传中，请稍后再试"
            } else if candidate.size <= 0 || candidate.size > UpdatePolicy.maximumAssetSize {
                reason = "安装包大小异常"
            } else if let sha256 = Self.sha256(fromDigest: candidate.digest) {
                asset = UpdateAsset(name: candidate.name, url: candidate.browserDownloadURL, size: candidate.size, sha256: sha256)
            } else {
                reason = "这个版本没有提供文件校验值，请手动下载安装"
            }
        } else {
            reason = "这个版本没有提供软件内更新的安装包，请手动下载安装"
        }

        let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .available(UpdateInfo(
            version: version,
            versionString: versionString,
            tagName: release.tagName,
            title: (title?.isEmpty ?? true) ? release.tagName : title!,
            notes: release.body ?? "",
            releasePage: release.htmlURL,
            publishedAt: release.publishedAt,
            asset: asset,
            installerURL: installer?.browserDownloadURL,
            manualOnlyReason: reason
        ))
    }

    /// "v1.4.0" → "1.4.0"
    public static func versionString(fromTag tag: String) -> String {
        var string = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("v") || string.hasPrefix("V") {
            string.removeFirst()
        }
        return string
    }

    /// "sha256:ABC…" → "abc…"（64 位十六进制）；格式不对返回 nil
    public static func sha256(fromDigest digest: String?) -> String? {
        guard let digest = digest?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              digest.hasPrefix("sha256:")
        else { return nil }
        let hex = String(digest.dropFirst("sha256:".count))
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }
}

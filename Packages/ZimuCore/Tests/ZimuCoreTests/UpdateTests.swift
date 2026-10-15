import XCTest
@testable import ZimuCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

/// 返回固定状态码、响应头和响应体的 HTTP 客户端
private final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    let error: Error?
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    init(status: Int = 200, headers: [String: String] = [:], body: Data = Data("[]".utf8), error: Error? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.error = error
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPResponseInfo) {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        return (body, HTTPResponseInfo(statusCode: status, contentType: "application/json", headers: headers))
    }

    func streamLines(_ request: URLRequest, handler: (HTTPStreamEvent) async throws -> Void) async throws {}
}

private let digestA = "sha256:" + String(repeating: "ab", count: 32)

private func releaseJSON(
    tag: String,
    name: String? = "字幕AI",
    body: String? = "## 更新内容",
    draft: Bool = false,
    prerelease: Bool = false,
    assets: [[String: Any]]? = nil
) -> [String: Any] {
    let version = UpdateChecker.versionString(fromTag: tag)
    var release: [String: Any] = [
        "tag_name": tag,
        "html_url": "https://github.com/owner/zimu-ai-releases/releases/tag/\(tag)",
        "published_at": "2026-10-15T08:00:00Z",
        "draft": draft,
        "prerelease": prerelease,
        "assets": assets ?? [
            [
                "name": "ZimuAI-\(version).zip",
                "size": 4_000_000,
                "state": "uploaded",
                "browser_download_url": "https://github.com/owner/zimu-ai-releases/releases/download/\(tag)/ZimuAI-\(version).zip",
                "digest": digestA,
            ],
            [
                "name": "ZimuAI-\(version).dmg",
                "size": 4_100_000,
                "state": "uploaded",
                "browser_download_url": "https://github.com/owner/zimu-ai-releases/releases/download/\(tag)/ZimuAI-\(version).dmg",
                "digest": NSNull(),
            ],
        ],
    ]
    release["name"] = name ?? NSNull()
    release["body"] = body ?? NSNull()
    return release
}

private func data(_ releases: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: releases)
}

final class SemanticVersionTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(SemanticVersion("v1.4.0"), SemanticVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(SemanticVersion("1.4"), SemanticVersion(major: 1, minor: 4))
        XCTAssertEqual(SemanticVersion(" 2 "), SemanticVersion(major: 2))
        XCTAssertEqual(SemanticVersion("1.4.0-beta.2")?.prerelease, ["beta", "2"])
        XCTAssertEqual(SemanticVersion("1.4.0+build.7"), SemanticVersion(major: 1, minor: 4, patch: 0))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
        XCTAssertNil(SemanticVersion("1..2"))
        XCTAssertNil(SemanticVersion("abc"))
        XCTAssertNil(SemanticVersion("1.4.0-"))
        XCTAssertNil(SemanticVersion("１.２"), "全角数字不是版本号")
        XCTAssertEqual(SemanticVersion("v1.4.0-rc.1")?.description, "1.4.0-rc.1")
    }

    func testOrdering() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.2.0", "1.10.0", "2.0.0"]
        let versions = ordered.compactMap(SemanticVersion.init)
        XCTAssertEqual(versions.count, ordered.count)
        XCTAssertEqual(versions, versions.sorted())
        XCTAssertTrue(SemanticVersion("1.4")! == SemanticVersion("1.4.0")!)
        XCTAssertFalse(SemanticVersion("1.4.0")! < SemanticVersion("1.4.0")!)
    }
}

final class UpdateCheckerTests: XCTestCase {
    let configuration = UpdateConfiguration(repository: "owner/zimu-ai-releases")
    let current = SemanticVersion("1.3.0")!

    private func checker(_ client: any HTTPClient) -> UpdateChecker {
        UpdateChecker(configuration: configuration, currentVersion: current, userAgent: "ZimuAI/1.3.0", client: client)
    }

    func testRequest() throws {
        let request = try checker(StubHTTPClient()).makeRequest()
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/owner/zimu-ai-releases/releases?per_page=10")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "ZimuAI/1.3.0")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "不能带任何凭据")
    }

    func testInvalidRepositoryIsRejected() {
        for repository in ["owner", "owner/repo/extra", "../x/y", "owner/repo?x=1", ""] {
            let bad = UpdateChecker(configuration: UpdateConfiguration(repository: repository), currentVersion: current, userAgent: "x", client: StubHTTPClient())
            XCTAssertThrowsError(try bad.makeRequest(), repository) { error in
                XCTAssertEqual(error as? UpdateCheckError, .invalidRepository(repository))
            }
        }
    }

    func testPicksHighestStableVersion() async throws {
        let client = StubHTTPClient(body: data([
            releaseJSON(tag: "v1.4.0"),
            releaseJSON(tag: "v1.10.0"),
            releaseJSON(tag: "v2.0.0", draft: true),
            releaseJSON(tag: "v1.11.0-beta.1"),
            releaseJSON(tag: "v1.12.0", prerelease: true),
            releaseJSON(tag: "nightly"),
        ]))
        guard case .available(let info) = try await checker(client).check() else { return XCTFail("应有新版本") }
        XCTAssertEqual(info.version, SemanticVersion("1.10.0"))
        XCTAssertEqual(info.versionString, "1.10.0")
        XCTAssertEqual(info.asset?.name, "ZimuAI-1.10.0.zip")
        XCTAssertEqual(info.asset?.sha256, String(repeating: "ab", count: 32))
        XCTAssertEqual(info.asset?.size, 4_000_000)
        XCTAssertEqual(info.installerURL?.lastPathComponent, "ZimuAI-1.10.0.dmg")
        XCTAssertNil(info.manualOnlyReason)
        XCTAssertEqual(info.title, "字幕AI")
        XCTAssertEqual(info.notes, "## 更新内容")
        XCTAssertNotNil(info.publishedAt)
    }

    func testUpToDate() async throws {
        let client = StubHTTPClient(body: data([releaseJSON(tag: "v1.3.0"), releaseJSON(tag: "v1.2.0")]))
        let latest = try await checker(client).check()
        XCTAssertEqual(latest, .upToDate(latest: SemanticVersion("1.3.0")))
        let onlyDrafts = StubHTTPClient(body: data([releaseJSON(tag: "v9.0.0", draft: true)]))
        let drafts = try await checker(onlyDrafts).check()
        XCTAssertEqual(drafts, .upToDate(latest: nil))
    }

    func testNullNameAndBodyFallBack() async throws {
        let client = StubHTTPClient(body: data([releaseJSON(tag: "v1.4.0", name: nil, body: nil)]))
        guard case .available(let info) = try await checker(client).check() else { return XCTFail() }
        XCTAssertEqual(info.title, "v1.4.0")
        XCTAssertEqual(info.notes, "")
    }

    func testAssetProblemsMakeUpdateManualOnly() throws {
        func evaluate(_ assets: [[String: Any]]) throws -> UpdateInfo? {
            let release = try UpdateChecker.decoder.decode([GitHubRelease].self, from: data([releaseJSON(tag: "v1.4.0", assets: assets)]))
            guard case .available(let info) = try UpdateChecker.evaluate(releases: release, currentVersion: current, configuration: configuration) else { return nil }
            return info
        }
        let url = "https://github.com/owner/zimu-ai-releases/releases/download/v1.4.0/ZimuAI-1.4.0.zip"
        let noDigest = try XCTUnwrap(evaluate([["name": "ZimuAI-1.4.0.zip", "size": 10, "state": "uploaded", "browser_download_url": url]]))
        XCTAssertNil(noDigest.asset)
        XCTAssertNotNil(noDigest.manualOnlyReason)

        let badDigest = try XCTUnwrap(evaluate([["name": "ZimuAI-1.4.0.zip", "size": 10, "state": "uploaded", "browser_download_url": url, "digest": "sha256:xyz"]]))
        XCTAssertNil(badDigest.asset)

        let sha1 = try XCTUnwrap(evaluate([["name": "ZimuAI-1.4.0.zip", "size": 10, "state": "uploaded", "browser_download_url": url, "digest": "sha1:" + String(repeating: "a", count: 40)]]))
        XCTAssertNil(sha1.asset)

        let uploading = try XCTUnwrap(evaluate([["name": "ZimuAI-1.4.0.zip", "size": 10, "state": "starter", "browser_download_url": url, "digest": digestA]]))
        XCTAssertNil(uploading.asset)

        let huge = try XCTUnwrap(evaluate([["name": "ZimuAI-1.4.0.zip", "size": UpdatePolicy.maximumAssetSize + 1, "state": "uploaded", "browser_download_url": url, "digest": digestA]]))
        XCTAssertNil(huge.asset)

        let wrongName = try XCTUnwrap(evaluate([["name": "ZimuAI-1.4.0-arm64.zip", "size": 10, "state": "uploaded", "browser_download_url": url, "digest": digestA]]))
        XCTAssertNil(wrongName.asset)
        XCTAssertNil(wrongName.installerURL)

        let upper = try XCTUnwrap(evaluate([["name": "ZimuAI-1.4.0.zip", "size": 10, "state": "uploaded", "browser_download_url": url, "digest": "SHA256:" + String(repeating: "AB", count: 32)]]))
        XCTAssertEqual(upper.asset?.sha256, String(repeating: "ab", count: 32))
    }

    func testHTTPErrors() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func error(_ client: StubHTTPClient) async -> UpdateCheckError? {
            do {
                _ = try await checker(client).check(now: now)
                return nil
            } catch {
                return error as? UpdateCheckError
            }
        }
        let limited = await error(StubHTTPClient(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000600"]))
        XCTAssertEqual(limited, .rateLimited(until: Date(timeIntervalSince1970: 1_000_600)))
        let retryAfter = await error(StubHTTPClient(status: 429, headers: ["Retry-After": "120"]))
        XCTAssertEqual(retryAfter, .rateLimited(until: now.addingTimeInterval(120)))
        let bare429 = await error(StubHTTPClient(status: 429))
        XCTAssertEqual(bare429, .rateLimited(until: nil))
        let forbidden = await error(StubHTTPClient(status: 403, headers: ["x-ratelimit-remaining": "12"]))
        XCTAssertEqual(forbidden, .http(403))
        let missing = await error(StubHTTPClient(status: 404))
        XCTAssertEqual(missing, .noReleases)
        let server = await error(StubHTTPClient(status: 502))
        XCTAssertEqual(server, .http(502))
        let empty = await error(StubHTTPClient(body: Data("[]".utf8)))
        XCTAssertEqual(empty, .noReleases)
        let garbage = await error(StubHTTPClient(body: Data("<html>".utf8)))
        XCTAssertEqual(garbage, .invalidResponse)
        let offline = await error(StubHTTPClient(error: URLError(.notConnectedToInternet)))
        if case .network = offline {} else { XCTFail("应为网络错误：\(String(describing: offline))") }
        XCTAssertNotNil(UpdateCheckError.rateLimited(until: now).errorDescription)
    }

    func testSHA256Digest() {
        XCTAssertEqual(UpdateChecker.sha256(fromDigest: digestA), String(repeating: "ab", count: 32))
        XCTAssertNil(UpdateChecker.sha256(fromDigest: nil))
        XCTAssertNil(UpdateChecker.sha256(fromDigest: "sha256:" + String(repeating: "a", count: 63)))
        XCTAssertNil(UpdateChecker.sha256(fromDigest: String(repeating: "a", count: 64)))
    }
}

final class UpdatePolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000)

    func testAutoCheckDue() {
        XCTAssertTrue(UpdatePolicy.isAutoCheckDue(now: now, lastSuccessfulCheck: nil, rateLimitedUntil: nil, enabled: true))
        XCTAssertFalse(UpdatePolicy.isAutoCheckDue(now: now, lastSuccessfulCheck: nil, rateLimitedUntil: nil, enabled: false))
        XCTAssertFalse(UpdatePolicy.isAutoCheckDue(now: now, lastSuccessfulCheck: now.addingTimeInterval(-3600), rateLimitedUntil: nil, enabled: true))
        XCTAssertTrue(UpdatePolicy.isAutoCheckDue(now: now, lastSuccessfulCheck: now.addingTimeInterval(-86_400), rateLimitedUntil: nil, enabled: true))
        XCTAssertFalse(UpdatePolicy.isAutoCheckDue(now: now, lastSuccessfulCheck: nil, rateLimitedUntil: now.addingTimeInterval(60), enabled: true))
        XCTAssertTrue(UpdatePolicy.isAutoCheckDue(now: now, lastSuccessfulCheck: nil, rateLimitedUntil: now.addingTimeInterval(-1), enabled: true))
        XCTAssertTrue(UpdatePolicy.isAutoCheckDue(now: now, lastSuccessfulCheck: now.addingTimeInterval(3600), rateLimitedUntil: nil, enabled: true), "时钟调回过去也要检查")
    }

    func testSkippedVersion() {
        let info = UpdateInfo(
            version: SemanticVersion("1.4.0")!, versionString: "1.4.0", tagName: "v1.4.0", title: "", notes: "",
            releasePage: URL(string: "https://github.com/o/r/releases/tag/v1.4.0")!, publishedAt: nil,
            asset: nil, installerURL: nil, manualOnlyReason: nil
        )
        XCTAssertFalse(UpdatePolicy.shouldNotify(info, skippedVersion: "1.4.0", manual: false))
        XCTAssertFalse(UpdatePolicy.shouldNotify(info, skippedVersion: "v1.4", manual: false))
        XCTAssertTrue(UpdatePolicy.shouldNotify(info, skippedVersion: "1.4.0", manual: true))
        XCTAssertTrue(UpdatePolicy.shouldNotify(info, skippedVersion: "1.3.9", manual: false))
        XCTAssertTrue(UpdatePolicy.shouldNotify(info, skippedVersion: "", manual: false))
    }

    func testDownloadURLAllowlist() {
        let repo = "owner/zimu-ai-releases"
        let allowed = [
            "https://github.com/owner/zimu-ai-releases/releases/download/v1.4.0/ZimuAI-1.4.0.zip",
            "https://GitHub.com/Owner/Zimu-AI-Releases/releases/download/v1.4.0/ZimuAI-1.4.0.zip",
            "https://release-assets.githubusercontent.com/github-production-release-asset/123/abc?sp=r&sig=x",
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/1/2",
            "https://github.com:443/owner/zimu-ai-releases/releases/download/v1/x.zip",
        ]
        let denied = [
            "http://github.com/owner/zimu-ai-releases/releases/download/v1.4.0/ZimuAI-1.4.0.zip",
            "https://github.com.evil.com/owner/zimu-ai-releases/releases/download/v1/x.zip",
            "https://evil.com/release-assets.githubusercontent.com/x",
            "https://github.com/other/repo/releases/download/v1/x.zip",
            "https://github.com/owner/zimu-ai-releases/archive/main.zip",
            "https://user:pass@github.com/owner/zimu-ai-releases/releases/download/v1/x.zip",
            "https://github.com:8443/owner/zimu-ai-releases/releases/download/v1/x.zip",
            "https://api.github.com/repos/owner/zimu-ai-releases/releases/assets/1",
            "file:///Applications/ZimuAI.app",
        ]
        for string in allowed {
            XCTAssertTrue(UpdatePolicy.isAllowedDownloadURL(URL(string: string)!, repository: repo), string)
        }
        for string in denied {
            XCTAssertFalse(UpdatePolicy.isAllowedDownloadURL(URL(string: string)!, repository: repo), string)
        }
    }
}

final class UpdateInstallSupportTests: XCTestCase {
    private func plist(_ values: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    func testBundleInfo() throws {
        let info = try BundleInfo(plistData: plist([
            "CFBundleIdentifier": "io.github.lingchenfs1.ZimuAI",
            "CFBundleShortVersionString": "1.4.0",
            "CFBundleVersion": "5",
            "CFBundleExecutable": "ZimuAI",
            "LSMinimumSystemVersion": "26.0",
        ]))
        XCTAssertEqual(info, BundleInfo(identifier: "io.github.lingchenfs1.ZimuAI", shortVersion: "1.4.0", build: "5", executable: "ZimuAI", minimumSystemVersion: "26.0"))
        XCTAssertThrowsError(try BundleInfo(plistData: Data("nope".utf8)))
        XCTAssertThrowsError(try BundleInfo(plistData: plist(["CFBundleShortVersionString": "1.0"]))) { error in
            XCTAssertEqual(error as? BundleInfo.ParseError, .missingField("CFBundleIdentifier"))
        }
    }

    func testStagedBundleValidation() {
        let good = BundleInfo(identifier: "id", shortVersion: "1.4.0", executable: "ZimuAI", minimumSystemVersion: "26.0")
        let v140 = SemanticVersion("1.4.0")!, v130 = SemanticVersion("1.3.0")!, os = SemanticVersion("26.1")!
        XCTAssertEqual(StagedBundleValidator.problems(staged: good, expectedIdentifier: "id", expectedVersion: v140, currentVersion: v130, systemVersion: os), [])
        XCTAssertEqual(StagedBundleValidator.problems(staged: good, expectedIdentifier: "other", expectedVersion: v140, currentVersion: v130, systemVersion: os).count, 1)
        XCTAssertEqual(StagedBundleValidator.problems(staged: good, expectedIdentifier: "id", expectedVersion: SemanticVersion("1.5.0")!, currentVersion: v130, systemVersion: os).count, 1)
        XCTAssertEqual(StagedBundleValidator.problems(staged: good, expectedIdentifier: "id", expectedVersion: v140, currentVersion: v140, systemVersion: os).count, 1, "不能装同版本")
        XCTAssertEqual(StagedBundleValidator.problems(staged: good, expectedIdentifier: "id", expectedVersion: v140, currentVersion: v130, systemVersion: SemanticVersion("15.5")!).count, 1)
        var noExecutable = good
        noExecutable.executable = nil
        XCTAssertEqual(StagedBundleValidator.problems(staged: noExecutable, expectedIdentifier: "id", expectedVersion: v140, currentVersion: v130, systemVersion: os).count, 1)
        var badVersion = good
        badVersion.shortVersion = "abc"
        XCTAssertEqual(StagedBundleValidator.problems(staged: badVersion, expectedIdentifier: "id", expectedVersion: v140, currentVersion: v130, systemVersion: os).count, 1)
    }

    func testInstallLocation() {
        XCTAssertNil(InstallLocationCheck.problem(bundlePath: "/Applications/ZimuAI.app", isOnReadOnlyVolume: false, parentWritable: true, bundleWritable: true))
        XCTAssertEqual(InstallLocationCheck.problem(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/ZimuAI.app", isOnReadOnlyVolume: true, parentWritable: false, bundleWritable: false), .translocated)
        XCTAssertEqual(InstallLocationCheck.problem(bundlePath: "/Volumes/字幕AI/ZimuAI.app", isOnReadOnlyVolume: true, parentWritable: false, bundleWritable: false), .readOnlyVolume)
        XCTAssertEqual(InstallLocationCheck.problem(bundlePath: "/Applications/ZimuAI.app", isOnReadOnlyVolume: false, parentWritable: false, bundleWritable: true), .notWritable)
        XCTAssertEqual(InstallLocationCheck.problem(bundlePath: "/Applications/ZimuAI.app", isOnReadOnlyVolume: false, parentWritable: true, bundleWritable: false), .notWritable)
        XCTAssertFalse(InstallLocationProblem.translocated.message.isEmpty)
    }

    func testPendingUpdateMarker() throws {
        let created = Date(timeIntervalSince1970: 3_000_000)
        let marker = PendingUpdateMarker(
            fromVersion: "1.4.0", toVersion: "1.4.1", installedPath: "/Applications/字幕AI.app",
            previousBundlePath: "/tmp/x/old.app", stagingRoot: "/tmp/x", launchAtLoginWasEnabled: true, createdAt: created
        )
        XCTAssertEqual(try PendingUpdateMarker.decode(marker.encoded()), marker)
        XCTAssertEqual(marker.outcome(runningVersion: "1.4.1", now: created.addingTimeInterval(30)), .succeeded)
        XCTAssertEqual(marker.outcome(runningVersion: "1.4.0", now: created.addingTimeInterval(30)), .notApplied)
        XCTAssertEqual(marker.outcome(runningVersion: "1.4.1", now: created.addingTimeInterval(2 * 86_400)), .stale)
        XCTAssertEqual(marker.outcome(runningVersion: "1.4.1", now: created.addingTimeInterval(-3600)), .stale)
    }

    func testSettingsDefaultsAndCompatibility() {
        let decoded = SettingsCoder.decode(Data(#"{"targetLanguage":"ja"}"#.utf8))
        XCTAssertTrue(decoded.autoCheckUpdates)
        XCTAssertEqual(decoded.skippedUpdateVersion, "")
        var settings = AppSettings()
        settings.autoCheckUpdates = false
        settings.skippedUpdateVersion = "1.4.0"
        XCTAssertEqual(SettingsCoder.decode(SettingsCoder.encode(settings)), settings)
    }
}

final class BundleSwapperTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(_ name: String, marker: String) throws -> String {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("marker"))
        return app.path
    }

    private func marker(_ path: String) -> String? {
        (try? String(contentsOfFile: path + "/marker", encoding: .utf8))
    }

    /// 只记录调用的操作，转发给真实的 rename
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        func record(_ call: String) { lock.withLock { calls.append(call) } }
    }

    func testFallbackRenamesWhenExchangeUnsupported() throws {
        let installed = try makeApp("字幕AI 'x'.app", marker: "old")
        let staged = try makeApp("staged.app", marker: "new")
        let backup = root.appendingPathComponent("backup.app").path
        let ops = BundleSwapOperations(exchange: { _, _ in ENOTSUP }, rename: BundleSwapOperations.live.rename)
        let previous = try BundleSwapper.swap(installed: installed, staged: staged, backup: backup, operations: ops)
        XCTAssertEqual(previous, backup)
        XCTAssertEqual(marker(installed), "new")
        XCTAssertEqual(marker(backup), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged))
    }

    func testLiveOperationsWork() throws {
        // macOS 上真实交换，Linux 上退回两次改名；两种情况结果一致
        let installed = try makeApp("ZimuAI.app", marker: "old")
        let staged = try makeApp("staged.app", marker: "new")
        let backup = root.appendingPathComponent("backup.app").path
        let previous = try BundleSwapper.swap(installed: installed, staged: staged, backup: backup)
        XCTAssertEqual(marker(installed), "new")
        XCTAssertEqual(marker(previous), "old")
    }

    func testExchangeSuccessDoesNotRename() throws {
        let recorder = Recorder()
        let ops = BundleSwapOperations(
            exchange: { a, b in recorder.record("exchange \(a) \(b)"); return 0 },
            rename: { a, b in recorder.record("rename \(a) \(b)"); return 0 }
        )
        let previous = try BundleSwapper.swap(installed: "/A/ZimuAI.app", staged: "/T/new.app", backup: "/T/old.app", operations: ops)
        XCTAssertEqual(previous, "/T/new.app")
        XCTAssertEqual(recorder.calls, ["exchange /A/ZimuAI.app /T/new.app"])
    }

    func testPermissionAndCrossVolumeErrors() {
        let denied = BundleSwapOperations(exchange: { _, _ in EPERM }, rename: { _, _ in 0 })
        XCTAssertThrowsError(try BundleSwapper.swap(installed: "/a", staged: "/b", backup: "/c", operations: denied)) { error in
            XCTAssertEqual(error as? BundleSwapError, .notPermitted(EPERM))
        }
        let cross = BundleSwapOperations(exchange: { _, _ in EXDEV }, rename: { _, _ in 0 })
        XCTAssertThrowsError(try BundleSwapper.swap(installed: "/a", staged: "/b", backup: "/c", operations: cross)) { error in
            XCTAssertEqual(error as? BundleSwapError, .crossVolume)
        }
        let fallbackDenied = BundleSwapOperations(exchange: { _, _ in ENOTSUP }, rename: { _, _ in EACCES })
        XCTAssertThrowsError(try BundleSwapper.swap(installed: "/a", staged: "/b", backup: "/c", operations: fallbackDenied)) { error in
            XCTAssertEqual(error as? BundleSwapError, .notPermitted(EACCES))
        }
        XCTAssertNotNil(BundleSwapError.notPermitted(EPERM).errorDescription)
    }

    func testSecondRenameFailureRestoresOldApp() throws {
        let installed = try makeApp("ZimuAI.app", marker: "old")
        let staged = try makeApp("staged.app", marker: "new")
        let backup = root.appendingPathComponent("backup.app").path
        let live = BundleSwapOperations.live.rename
        let ops = BundleSwapOperations(
            exchange: { _, _ in ENOTSUP },
            rename: { from, to in from == staged ? EIO : live(from, to) }
        )
        XCTAssertThrowsError(try BundleSwapper.swap(installed: installed, staged: staged, backup: backup, operations: ops)) { error in
            XCTAssertEqual(error as? BundleSwapError, .failed(step: "放入新版本", errno: EIO))
        }
        XCTAssertEqual(marker(installed), "old", "旧版本必须回到原处")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup))
        XCTAssertEqual(marker(staged), "new")
    }

    func testRollbackFailureReportsWhereOldAppIs() throws {
        let installed = try makeApp("ZimuAI.app", marker: "old")
        let staged = try makeApp("staged.app", marker: "new")
        let backup = root.appendingPathComponent("backup.app").path
        let live = BundleSwapOperations.live.rename
        let ops = BundleSwapOperations(
            exchange: { _, _ in ENOTSUP },
            rename: { from, to in (from == staged || from == backup) ? EIO : live(from, to) }
        )
        XCTAssertThrowsError(try BundleSwapper.swap(installed: installed, staged: staged, backup: backup, operations: ops)) { error in
            XCTAssertEqual(error as? BundleSwapError, .rollbackFailed(previousAt: backup))
        }
        XCTAssertEqual(marker(backup), "old")
    }
}

final class ProcessRunnerTests: XCTestCase {
    func testRunCapturesOutputAndStatus() async throws {
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "echo hi; echo err >&2; exit 3"], timeout: 10)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdoutText, "hi\n")
        XCTAssertEqual(result.stderrText, "err\n")
        XCTAssertFalse(result.timedOut)
    }

    func testRunTimesOut() async throws {
        let start = Date()
        // 用 exec 避免留下孙进程：Linux 上的 Foundation 要等所有继承了内部套接字的子孙进程都退出才报告结束
        let result = try await ProcessRunner.run("/bin/sh", ["-c", "exec sleep 10"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunMissingExecutableThrows() async {
        do {
            _ = try await ProcessRunner.run("/nonexistent/tool", [], timeout: 1)
            XCTFail("should throw")
        } catch {}
    }

    func testSpawnDetachedWritesLog() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("spawn-\(UUID().uuidString)/update.log")
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent()) }
        try ProcessRunner.spawnDetached("/bin/sh", ["-c", "echo first"], logFile: log)
        try ProcessRunner.spawnDetached("/bin/sh", ["-c", "echo second >&2"], logFile: log)
        let deadline = Date().addingTimeInterval(5)
        var text = ""
        while Date() < deadline {
            text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if text.contains("first") && text.contains("second") { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"))
    }
}

/// 真实运行 /bin/sh 测试重启脚本
final class RelaunchScriptTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/sh"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// 启动一个会自己退出的子进程，返回它（Foundation 的 Process 会回收它，退出后 kill -0 失败）
    private func sleeper(_ seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep \(seconds)"]
        try process.run()
        return process
    }

    /// 打开命令的替身：把收到的 App 路径写进记录文件
    private func launcher(record: URL) -> [String] {
        ["/bin/sh", "-c", #"printf '%s' "$1" > "$0""#, record.path]
    }

    private func makeApp(_ name: String) throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        return app
    }

    func testWaitsForExitThenLaunches() async throws {
        let app = try makeApp(#"字幕AI a b'c"d$e.app"#)
        let record = root.appendingPathComponent("record")
        let child = try sleeper("0.6")
        let start = Date()
        let result = try await ProcessRunner.run(
            "/bin/sh",
            UpdateScripts.relaunchArguments(pid: child.processIdentifier, appPath: app.path, timeoutSeconds: 10, launcher: launcher(record: record)),
            timeout: 20
        )
        XCTAssertEqual(result.status, 0, result.stdoutText + result.stderrText)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.5, "要等旧进程退出")
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), app.path)
        XCTAssertTrue(result.stdoutText.contains("launching"))
        XCTAssertTrue(result.stdoutText.contains("done"))
    }

    func testTimeoutDoesNotLaunch() async throws {
        let app = try makeApp("ZimuAI.app")
        let record = root.appendingPathComponent("record")
        let child = try sleeper("30")
        defer { kill(child.processIdentifier, SIGKILL) }
        let result = try await ProcessRunner.run(
            "/bin/sh",
            UpdateScripts.relaunchArguments(pid: child.processIdentifier, appPath: app.path, timeoutSeconds: 1, launcher: launcher(record: record)),
            timeout: 20
        )
        XCTAssertEqual(result.status, 65)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testMissingAppAndBadArguments() async throws {
        let record = root.appendingPathComponent("record")
        let finished = try sleeper("0")
        finished.waitUntilExit()
        let missing = try await ProcessRunner.run(
            "/bin/sh",
            UpdateScripts.relaunchArguments(pid: finished.processIdentifier, appPath: root.appendingPathComponent("nope.app").path, timeoutSeconds: 5, launcher: launcher(record: record)),
            timeout: 20
        )
        XCTAssertEqual(missing.status, 66)

        let app = try makeApp("ZimuAI.app")
        let badPid = try await ProcessRunner.run("/bin/sh", UpdateScripts.relaunchArguments(pid: 0, appPath: app.path, launcher: launcher(record: record)), timeout: 20)
        XCTAssertEqual(badPid.status, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testLauncherFailureIsReported() async throws {
        let app = try makeApp("ZimuAI.app")
        let finished = try sleeper("0")
        finished.waitUntilExit()
        let result = try await ProcessRunner.run(
            "/bin/sh",
            UpdateScripts.relaunchArguments(pid: finished.processIdentifier, appPath: app.path, timeoutSeconds: 5, launcher: ["/bin/sh", "-c", "exit 9"]),
            timeout: 20
        )
        XCTAssertEqual(result.status, 67)
    }
}

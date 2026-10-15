import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// 交换新旧 App 用到的文件系统操作（可注入，便于测试失败路径）。返回 0 表示成功，否则为 errno
public struct BundleSwapOperations: Sendable {
    public var exchange: @Sendable (_ first: String, _ second: String) -> Int32
    public var rename: @Sendable (_ from: String, _ to: String) -> Int32

    public init(
        exchange: @escaping @Sendable (String, String) -> Int32,
        rename: @escaping @Sendable (String, String) -> Int32
    ) {
        self.exchange = exchange
        self.rename = rename
    }

    public static var live: BundleSwapOperations {
        BundleSwapOperations(
            exchange: { first, second in
                #if canImport(Darwin)
                return renamex_np(first, second, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
                #else
                return ENOTSUP
                #endif
            },
            rename: { from, to in
                #if canImport(Darwin)
                return Darwin.rename(from, to) == 0 ? 0 : errno
                #else
                return Glibc.rename(from, to) == 0 ? 0 : errno
                #endif
            }
        )
    }
}

public enum BundleSwapError: Error, Equatable, LocalizedError {
    /// 没有权限（文件夹不可写，或被系统的 App 管理保护拦截）
    case notPermitted(Int32)
    /// 新旧 App 不在同一个卷上，无法原子替换
    case crossVolume
    case failed(step: String, errno: Int32)
    /// 安装失败且没能把旧版本放回原处
    case rollbackFailed(previousAt: String)

    public var errorDescription: String? {
        switch self {
        case .notPermitted:
            return "没有权限替换字幕AI（可能需要管理员账号，或被 系统设置 › 隐私与安全性 › App 管理 阻止）"
        case .crossVolume:
            return "新版本和当前安装位置不在同一个磁盘上，无法替换"
        case .failed(let step, let code):
            return "替换应用失败（\(step)，错误码 \(code)）"
        case .rollbackFailed(let path):
            return "替换应用失败，旧版本留在：\(path)"
        }
    }
}

/// 在软件仍在运行时替换 App 包（决策 D21）：优先原子交换，系统不支持时退回两次改名并在失败时还原
public enum BundleSwapper {
    /// 用 staged 替换 installed，返回旧版本现在所在的路径（调用方负责之后删除）。
    /// - Parameter backup: 不支持原子交换时旧版本临时移到这里（必须在同一个卷上且尚不存在）
    @discardableResult
    public static func swap(
        installed: String,
        staged: String,
        backup: String,
        operations: BundleSwapOperations = .live
    ) throws -> String {
        let status = operations.exchange(installed, staged)
        switch status {
        case 0:
            // 交换后旧版本在 staged 路径上
            return staged
        case EPERM, EACCES:
            throw BundleSwapError.notPermitted(status)
        case EXDEV:
            throw BundleSwapError.crossVolume
        case ENOTSUP, EINVAL, ENOSYS:
            break
        default:
            throw BundleSwapError.failed(step: "交换", errno: status)
        }

        // 后备：旧 → 备份，新 → 原位置；第二步失败时把旧版本放回去
        let moveOld = operations.rename(installed, backup)
        guard moveOld == 0 else {
            throw error(for: moveOld, step: "移走旧版本")
        }
        let moveNew = operations.rename(staged, installed)
        guard moveNew == 0 else {
            guard operations.rename(backup, installed) == 0 else {
                throw BundleSwapError.rollbackFailed(previousAt: backup)
            }
            throw error(for: moveNew, step: "放入新版本")
        }
        return backup
    }

    private static func error(for status: Int32, step: String) -> BundleSwapError {
        switch status {
        case EPERM, EACCES: return .notPermitted(status)
        case EXDEV: return .crossVolume
        default: return .failed(step: step, errno: status)
        }
    }
}

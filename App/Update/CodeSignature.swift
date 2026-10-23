import Foundation
import Security

/// 代码签名检查（决策 D21 / D22）：当前 App 的签名身份，以及新版本是否出自同一签名
enum CodeSignature {
    struct Identity {
        /// ad-hoc 签名或未签名：没有固定身份，只能做完整性校验
        let isAdHocOrUnsigned: Bool
        /// 指定要求（designated requirement），例如 `identifier "…" and certificate leaf = H"…"`
        let designatedRequirement: SecRequirement?
        let requirementText: String?
    }

    enum CheckError: LocalizedError {
        case status(String, OSStatus)
        case invalid(OSStatus, String?)

        var errorDescription: String? {
            switch self {
            case .status(let step, let status):
                return "无法读取代码签名（\(step)，错误码 \(status)）"
            case .invalid(let status, let detail):
                if status == errSecCSReqFailed {
                    return "新版本的签名与当前版本不一致，已拒绝安装"
                }
                return "新版本的代码签名无效（错误码 \(status)）\(detail.map { "：\($0)" } ?? "")"
            }
        }
    }

    /// 当前运行的 App 的签名身份（应在启动时读取，替换 App 包之前）
    static func runningApp() throws -> Identity {
        var code: SecCode?
        try check(SecCodeCopySelf([], &code), "读取当前进程")
        var staticCode: SecStaticCode?
        try check(SecCodeCopyStaticCode(code!, [], &staticCode), "读取当前 App")
        return try identity(of: staticCode!)
    }

    static func identity(of staticCode: SecStaticCode) throws -> Identity {
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information), "读取签名信息")
        let info = information as? [String: Any] ?? [:]
        let flags = SecCodeSignatureFlags(rawValue: (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0)
        let certificates = info[kSecCodeInfoCertificates as String] as? [Any] ?? []
        let isAdHoc = info[kSecCodeInfoIdentifier as String] == nil || flags.contains(.adhoc) || certificates.isEmpty
        guard !isAdHoc else {
            return Identity(isAdHocOrUnsigned: true, designatedRequirement: nil, requirementText: nil)
        }
        var requirement: SecRequirement?
        try check(SecCodeCopyDesignatedRequirement(staticCode, [], &requirement), "读取签名要求")
        var text: CFString?
        _ = SecRequirementCopyString(requirement!, [], &text)
        return Identity(isAdHocOrUnsigned: false, designatedRequirement: requirement, requirementText: text as String?)
    }

    /// 严格校验 App 包（所有架构、嵌套代码）；requirement 不为 nil 时还要求满足它（同一签名）
    static func validate(bundle: URL, satisfying requirement: SecRequirement?) throws {
        var staticCode: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode), "读取新版本")
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode!, flags, requirement, &error)
        guard status == errSecSuccess else {
            throw CheckError.invalid(status, error?.takeRetainedValue().localizedDescription)
        }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == errSecSuccess else { throw CheckError.status(step, status) }
    }
}

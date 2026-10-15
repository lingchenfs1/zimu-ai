import Foundation

/// 更新后重启用的脚本（决策 D21）。
///
/// 新版本已经在软件运行时换好了，脚本只负责等旧进程退出后重新打开 App。
/// 脚本文本是常量，进程号和路径只作为位置参数传入，不拼接进脚本，避免路径里的特殊字符被当成命令。
public enum UpdateScripts {
    /// 参数：$1 进程号，$2 App 路径，$3 最多等待秒数，之后是打开 App 的命令（默认 /usr/bin/open）。
    /// 退出码：0 成功；64 参数错误；65 等待超时；66 App 不存在；67 打开失败
    public static let relaunch = #"""
    set -u
    pid=$1; app=$2; limit=$3; shift 3
    [ "$#" -gt 0 ] || set -- /usr/bin/open
    log() { printf '%s [relaunch] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
    case $pid in ''|0|*[!0-9]*) log "bad pid: $pid"; exit 64;; esac
    case $limit in ''|*[!0-9]*) log "bad limit: $limit"; exit 64;; esac
    log "waiting for pid $pid (max ${limit}s)"
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge "$limit" ]; then log "pid $pid still alive after ${limit}s; not relaunching"; exit 65; fi
      sleep 1
      waited=$((waited + 1))
    done
    [ -d "$app" ] || { log "app not found: $app"; exit 66; }
    log "launching $app"
    "$@" "$app"
    status=$?
    [ "$status" -eq 0 ] || { log "launcher failed ($status)"; exit 67; }
    log "done"
    exit 0
    """#

    /// `/bin/sh` 的参数：`-c <脚本> sh <pid> <App> <秒数> <打开命令…>`
    public static func relaunchArguments(
        pid: Int32,
        appPath: String,
        timeoutSeconds: Int = 30,
        launcher: [String] = ["/usr/bin/open"]
    ) -> [String] {
        ["-c", relaunch, "sh", String(pid), appPath, String(timeoutSeconds)] + launcher
    }
}

import Foundation

/// 在识别文本中寻找句子边界
public enum SentenceSplitter {
    static let strongTerminators: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "؟", "।"]
    /// 中日文句末标点后面不需要空格
    static let noSpaceTerminators: Set<Character> = ["。", "！", "？", "…"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "）", "」", "』", "】", "》", "]"]
    static let softBreaks: Set<Character> = [",", "，", "、", ";", "；", ":", "：", "—"]
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e", "u.s", "u.k",
        "no", "inc", "ltd", "co", "mt", "jan", "feb", "mar", "apr", "aug", "sept", "oct", "nov", "dec",
    ]

    /// 返回第一个句子结束的位置（句末标点及其后的引号之后）。
    /// 如果没有句子结束且文本超过 `maxLength`，返回一个软断点（逗号 / 空格）或硬切位置。
    public static func firstBoundary(in text: String, maxLength: Int) -> String.Index? {
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if strongTerminators.contains(ch) {
                var j = text.index(after: i)
                while j < text.endIndex, strongTerminators.contains(text[j]) || closers.contains(text[j]) {
                    j = text.index(after: j)
                }
                let atEnd = j == text.endIndex
                let followedBySpace = !atEnd && text[j].isWhitespace
                let noSpaceNeeded = noSpaceTerminators.contains(ch)
                let isAbbrev = ch == "." && isAbbreviation(in: text, periodIndex: i)
                if (atEnd || followedBySpace || noSpaceNeeded) && !isAbbrev {
                    return j
                }
                i = j
                continue
            }
            i = text.index(after: i)
        }

        guard maxLength > 0, text.count > maxLength else { return nil }
        let limit = text.index(text.startIndex, offsetBy: maxLength)
        var lastSoft: String.Index?
        var lastSpace: String.Index?
        var k = text.startIndex
        var offset = 0
        var softOffset = 0
        while k < limit {
            let c = text[k]
            if softBreaks.contains(c) {
                lastSoft = text.index(after: k)
                softOffset = offset + 1
            } else if c.isWhitespace, k > text.startIndex {
                lastSpace = k
            }
            k = text.index(after: k)
            offset += 1
        }
        if let soft = lastSoft, softOffset >= maxLength / 3 {
            return soft
        }
        return lastSpace ?? lastSoft ?? limit
    }

    /// 最后一个停顿标点（逗号、分号等）之后的位置；只在它位于文本后 60% 之内（前半句不会太短）时返回
    public static func lastSoftBreak(in text: String) -> String.Index? {
        guard let index = text.lastIndex(where: { softBreaks.contains($0) }) else { return nil }
        let after = text.index(after: index)
        guard after < text.endIndex else { return nil }
        let offset = text.distance(from: text.startIndex, to: after)
        return Double(offset) >= Double(text.count) * 0.4 ? after : nil
    }

    /// 句点前的单词是否是常见缩写（Mr. / Dr. / e.g.）或单个大写字母（姓名缩写）
    static func isAbbreviation(in text: String, periodIndex: String.Index) -> Bool {
        var start = periodIndex
        while start > text.startIndex {
            let prev = text.index(before: start)
            let c = text[prev]
            if c.isLetter || c == "." {
                start = prev
            } else {
                break
            }
        }
        let word = String(text[start..<periodIndex])
        guard !word.isEmpty else { return false }
        if word.count == 1, let first = word.first, first.isUppercase {
            return true
        }
        return abbreviations.contains(word.lowercased())
    }
}

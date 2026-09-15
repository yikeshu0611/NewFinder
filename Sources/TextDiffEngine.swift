import Foundation
import AppKit

enum DiffOp {
    case equal
    case insert
    case delete
    case replace
}

struct DiffLine {
    let op: DiffOp
    let leftText: String?
    let rightText: String?
}

enum CompareLineKind {
    case equal
    case insert
    case delete
    case replace
    case spacer
}

struct AlignedCell {
    var text: String?
    var kind: CompareLineKind
    var intraUTF16: [NSRange]
}

enum TextDiffEngine {
    private static let maxDPCells = 4_000_000

    /// Lines as NSString `lineRange` sees them (matches editor highlighting indices).
    static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        let ns = text as NSString
        var lines: [String] = []
        var loc = 0
        while loc < ns.length {
            let r = ns.lineRange(for: NSRange(location: loc, length: 0))
            var s = ns.substring(with: r)
            if s.hasSuffix("\r\n") {
                s = String(s.dropLast(2))
            } else if s.hasSuffix("\n") || s.hasSuffix("\r") {
                s = String(s.dropLast())
            }
            lines.append(s)
            loc = NSMaxRange(r)
        }
        return lines
    }

    static func joinLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    static func diffLines(left: String, right: String) -> [DiffLine] {
        let a = splitLines(left)
        let b = splitLines(right)
        let raw = lcsLineOps(a, b)
        return mergeReplaces(raw)
    }

    /// One column per file, equal row counts (Code Compare alignment).
    static func alignedColumns(_ texts: [String]) -> [[AlignedCell]] {
        guard !texts.isEmpty else { return [] }
        if texts.count == 1 {
            return [splitLines(texts[0]).map { AlignedCell(text: $0, kind: .equal, intraUTF16: []) }]
        }
        if texts.count == 2 {
            return twoWayColumns(texts[0], texts[1])
        }
        return nWayVersusBase(texts)
    }

    static func loadText(from url: URL) -> Result<String, Error> {
        do {
            let data = try Data(contentsOf: url)
            if let utf8 = String(data: data, encoding: .utf8) {
                return .success(utf8)
            }
            if let latin1 = String(data: data, encoding: .isoLatin1) {
                return .success(latin1)
            }
            return .failure(NSError(
                domain: "TextDiffEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法以文本编码读取文件"]
            ))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Two-way

    private static func twoWayColumns(_ left: String, _ right: String) -> [[AlignedCell]] {
        var leftCol: [AlignedCell] = []
        var rightCol: [AlignedCell] = []
        for line in diffLines(left: left, right: right) {
            switch line.op {
            case .equal:
                leftCol.append(AlignedCell(text: line.leftText, kind: .equal, intraUTF16: []))
                rightCol.append(AlignedCell(text: line.rightText, kind: .equal, intraUTF16: []))
            case .delete:
                leftCol.append(AlignedCell(text: line.leftText, kind: .delete, intraUTF16: []))
                rightCol.append(AlignedCell(text: nil, kind: .spacer, intraUTF16: []))
            case .insert:
                leftCol.append(AlignedCell(text: nil, kind: .spacer, intraUTF16: []))
                rightCol.append(AlignedCell(text: line.rightText, kind: .insert, intraUTF16: []))
            case .replace:
                let (lh, rh) = intraUTF16Ranges(left: line.leftText ?? "", right: line.rightText ?? "")
                leftCol.append(AlignedCell(text: line.leftText, kind: .replace, intraUTF16: lh))
                rightCol.append(AlignedCell(text: line.rightText, kind: .replace, intraUTF16: rh))
            }
        }
        return [leftCol, rightCol]
    }

    private static func lcsLineOps(_ a: [String], _ b: [String]) -> [DiffLine] {
        let n = a.count
        let m = b.count
        if n == 0 && m == 0 { return [] }
        if n * m > maxDPCells {
            return greedyLineOps(a, b)
        }

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in 1 ... n {
                for j in 1 ... m {
                    if a[i - 1] == b[j - 1] {
                        dp[i][j] = dp[i - 1][j - 1] + 1
                    } else {
                        dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                    }
                }
            }
        }

        var result: [DiffLine] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                result.append(DiffLine(op: .equal, leftText: a[i - 1], rightText: b[j - 1]))
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || dp[i][j - 1] >= (i > 0 ? dp[i - 1][j] : -1) {
                result.append(DiffLine(op: .insert, leftText: nil, rightText: b[j - 1]))
                j -= 1
            } else {
                result.append(DiffLine(op: .delete, leftText: a[i - 1], rightText: nil))
                i -= 1
            }
        }
        result.reverse()
        return result
    }

    private static func greedyLineOps(_ a: [String], _ b: [String]) -> [DiffLine] {
        var result: [DiffLine] = []
        let n = max(a.count, b.count)
        for i in 0 ..< n {
            let l = i < a.count ? a[i] : nil
            let r = i < b.count ? b[i] : nil
            if let l, let r {
                result.append(DiffLine(op: l == r ? .equal : .replace, leftText: l, rightText: r))
            } else if let l {
                result.append(DiffLine(op: .delete, leftText: l, rightText: nil))
            } else {
                result.append(DiffLine(op: .insert, leftText: nil, rightText: r))
            }
        }
        return result
    }

    private static func mergeReplaces(_ lines: [DiffLine]) -> [DiffLine] {
        var merged: [DiffLine] = []
        var i = 0
        while i < lines.count {
            if i + 1 < lines.count,
               lines[i].op == .delete,
               lines[i + 1].op == .insert,
               let left = lines[i].leftText,
               let right = lines[i + 1].rightText {
                merged.append(DiffLine(op: .replace, leftText: left, rightText: right))
                i += 2
            } else {
                merged.append(lines[i])
                i += 1
            }
        }
        return merged
    }

    // MARK: - N-way versus first file

    private enum BaseState {
        case same
        case missing
        case changed(String, [NSRange])
    }

    private static func nWayVersusBase(_ texts: [String]) -> [[AlignedCell]] {
        let base = splitLines(texts[0])
        let n = base.count
        var befores: [[[String]]] = []
        var states: [[BaseState]] = []

        for other in texts.dropFirst() {
            let diff = diffLines(left: texts[0], right: other)
            var before = Array(repeating: [String](), count: n + 1)
            var state = Array(repeating: BaseState.same, count: n)
            var i = 0
            for d in diff {
                switch d.op {
                case .equal:
                    i += 1
                case .delete:
                    if i < n { state[i] = .missing }
                    i += 1
                case .insert:
                    before[min(i, n)].append(d.rightText ?? "")
                case .replace:
                    if i < n {
                        let rhs = d.rightText ?? ""
                        let (_, rh) = intraUTF16Ranges(left: d.leftText ?? "", right: rhs)
                        state[i] = .changed(rhs, rh)
                    }
                    i += 1
                }
            }
            befores.append(before)
            states.append(state)
        }

        let fileCount = texts.count
        var cols = Array(repeating: [AlignedCell](), count: fileCount)
        for k in 0 ... n {
            let maxIns = befores.map { $0[k].count }.max() ?? 0
            for r in 0 ..< maxIns {
                cols[0].append(AlignedCell(text: nil, kind: .spacer, intraUTF16: []))
                for f in 1 ..< fileCount {
                    let arr = befores[f - 1][k]
                    if r < arr.count {
                        cols[f].append(AlignedCell(text: arr[r], kind: .insert, intraUTF16: []))
                    } else {
                        cols[f].append(AlignedCell(text: nil, kind: .spacer, intraUTF16: []))
                    }
                }
            }
            if k < n {
                var baseKind: CompareLineKind = .equal
                for f in 0 ..< states.count {
                    switch states[f][k] {
                    case .missing:
                        if baseKind == .equal { baseKind = .delete }
                    case .changed:
                        baseKind = .replace
                    case .same:
                        break
                    }
                }
                var baseIntra: [NSRange] = []
                if baseKind == .replace, let firstChanged = states.first(where: {
                    if case .changed = $0[k] { return true }
                    return false
                }), case .changed(let rhs, _) = firstChanged[k] {
                    (baseIntra, _) = intraUTF16Ranges(left: base[k], right: rhs)
                }
                cols[0].append(AlignedCell(text: base[k], kind: baseKind, intraUTF16: baseIntra))
                for f in 1 ..< fileCount {
                    switch states[f - 1][k] {
                    case .same:
                        cols[f].append(AlignedCell(text: base[k], kind: .equal, intraUTF16: []))
                    case .missing:
                        cols[f].append(AlignedCell(text: nil, kind: .spacer, intraUTF16: []))
                    case .changed(let text, let intra):
                        cols[f].append(AlignedCell(text: text, kind: .replace, intraUTF16: intra))
                    }
                }
            }
        }
        return cols
    }

    /// Per-file line highlights without inserting blank spacer rows (edits stay independent).
    /// Returns one array per text: kind for each original line index.
    static func independentHighlights(_ texts: [String]) -> [(kinds: [CompareLineKind], intras: [[NSRange]])] {
        guard !texts.isEmpty else { return [] }
        if texts.count == 1 {
            let n = splitLines(texts[0]).count
            return [(Array(repeating: .equal, count: n), Array(repeating: [], count: n))]
        }
        if texts.count == 2 {
            return twoWayIndependent(texts[0], texts[1])
        }
        return nWayIndependent(texts)
    }

    private static func twoWayIndependent(_ left: String, _ right: String) -> [(kinds: [CompareLineKind], intras: [[NSRange]])] {
        let a = splitLines(left)
        let b = splitLines(right)
        var leftKinds = Array(repeating: CompareLineKind.equal, count: a.count)
        var rightKinds = Array(repeating: CompareLineKind.equal, count: b.count)
        var leftIntra = Array(repeating: [NSRange](), count: a.count)
        var rightIntra = Array(repeating: [NSRange](), count: b.count)
        var li = 0
        var ri = 0
        for line in diffLines(left: left, right: right) {
            switch line.op {
            case .equal:
                li += 1
                ri += 1
            case .delete:
                if li < leftKinds.count { leftKinds[li] = .delete }
                li += 1
            case .insert:
                if ri < rightKinds.count { rightKinds[ri] = .insert }
                ri += 1
            case .replace:
                let (lh, rh) = intraUTF16Ranges(left: line.leftText ?? "", right: line.rightText ?? "")
                if li < leftKinds.count {
                    leftKinds[li] = .replace
                    leftIntra[li] = lh
                }
                if ri < rightKinds.count {
                    rightKinds[ri] = .replace
                    rightIntra[ri] = rh
                }
                li += 1
                ri += 1
            }
        }
        return [(leftKinds, leftIntra), (rightKinds, rightIntra)]
    }

    private static func nWayIndependent(_ texts: [String]) -> [(kinds: [CompareLineKind], intras: [[NSRange]])] {
        // File 0 is base; each other file vs base. Base line is delete/replace if any other differs.
        let baseLines = splitLines(texts[0])
        var result: [(kinds: [CompareLineKind], intras: [[NSRange]])] = []
        var baseKinds = Array(repeating: CompareLineKind.equal, count: baseLines.count)
        var baseIntra = Array(repeating: [NSRange](), count: baseLines.count)

        for other in texts.dropFirst() {
            let pair = twoWayIndependent(texts[0], other)
            let bk = pair[0].kinds
            let bi = pair[0].intras
            let ok = pair[1].kinds
            let oi = pair[1].intras
            for i in 0 ..< baseKinds.count where i < bk.count {
                switch bk[i] {
                case .delete:
                    if baseKinds[i] == .equal { baseKinds[i] = .delete }
                case .replace:
                    baseKinds[i] = .replace
                    if baseIntra[i].isEmpty { baseIntra[i] = bi[i] }
                default:
                    break
                }
            }
            result.append((ok, oi))
        }
        result.insert((baseKinds, baseIntra), at: 0)
        return result
    }

    // MARK: - Intra-line

    static func intraUTF16Ranges(left: String, right: String) -> ([NSRange], [NSRange]) {
        let a = Array(left)
        let b = Array(right)
        if a.isEmpty && b.isEmpty { return ([], []) }
        if a.count * b.count > 250_000 {
            return (
                [NSRange(location: 0, length: (left as NSString).length)],
                [NSRange(location: 0, length: (right as NSString).length)]
            )
        }
        let n = a.count
        let m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in 1 ... n {
                for j in 1 ... m {
                    if a[i - 1] == b[j - 1] {
                        dp[i][j] = dp[i - 1][j - 1] + 1
                    } else {
                        dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                    }
                }
            }
        }
        var leftChars = Array(repeating: false, count: n)
        var rightChars = Array(repeating: false, count: m)
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || dp[i][j - 1] >= (i > 0 ? dp[i - 1][j] : -1) {
                rightChars[j - 1] = true
                j -= 1
            } else if i > 0 {
                leftChars[i - 1] = true
                i -= 1
            } else {
                rightChars[j - 1] = true
                j -= 1
            }
        }
        return (
            utf16Runs(in: left, markedChars: leftChars),
            utf16Runs(in: right, markedChars: rightChars)
        )
    }

    private static func utf16Runs(in string: String, markedChars: [Bool]) -> [NSRange] {
        var runs: [NSRange] = []
        var charIndex = 0
        var utf16 = 0
        var runStart: Int?
        var runLen = 0
        for ch in string {
            let w = String(ch).utf16.count
            if charIndex < markedChars.count, markedChars[charIndex] {
                if runStart == nil {
                    runStart = utf16
                    runLen = w
                } else {
                    runLen += w
                }
            } else if let start = runStart {
                runs.append(NSRange(location: start, length: runLen))
                runStart = nil
                runLen = 0
            }
            utf16 += w
            charIndex += 1
        }
        if let start = runStart {
            runs.append(NSRange(location: start, length: runLen))
        }
        return runs
    }
}

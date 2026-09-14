import Foundation
import PlsInputCore

// plsbot：用贪心机器人跑一批种子，输出峰值分布、跨档率、坏题嫌疑名单。
// 只解析 CommandLine.arguments，不引入任何依赖。

// MARK: - 命令行参数

struct Options {
    var from: String?
    var days = 365
    var random = 200
    var configPath: String?
    var interval = 0.35
    var jsonPath: String?
    var verbose = false
    var singleSeed: String?
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case badValue(String, String)
    case unknown(String)
    case configUnreadable(String)

    var description: String {
        switch self {
        case .missingValue(let flag): return "\(flag) 缺少取值"
        case .badValue(let flag, let value): return "\(flag) 的取值 \(value) 无法解析"
        case .unknown(let flag): return "未知参数 \(flag)"
        case .configUnreadable(let path): return "配置文件 \(path) 读不出来"
        }
    }
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    func next(_ flag: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw CLIError.missingValue(flag) }
        return arguments[index]
    }
    while index < arguments.count {
        let flag = arguments[index]
        switch flag {
        case "--from":
            options.from = try next(flag)
        case "--days":
            let raw = try next(flag)
            guard let value = Int(raw), value >= 0 else { throw CLIError.badValue(flag, raw) }
            options.days = value
        case "--random":
            let raw = try next(flag)
            guard let value = Int(raw), value >= 0 else { throw CLIError.badValue(flag, raw) }
            options.random = value
        case "--config":
            options.configPath = try next(flag)
        case "--interval":
            let raw = try next(flag)
            guard let value = Double(raw), value > 0 else { throw CLIError.badValue(flag, raw) }
            options.interval = value
        case "--json":
            options.jsonPath = try next(flag)
        case "--verbose":
            options.verbose = true
        case "--seed":
            options.singleSeed = try next(flag)
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            throw CLIError.unknown(flag)
        }
        index += 1
    }
    return options
}

func printUsage() {
    print(
        """
        plsbot —— PlsInput 贪心校准机器人

          --from yyyy-MM-dd   起始题日，默认今天（Asia/Shanghai）
          --days N            连续跑多少天的每日种子，默认 365
          --random N          额外跑多少个随机种子 PlsInput-random-<i>，默认 200
          --config path       远程配置 JSON，按题日取平衡参数；默认内置参数
          --interval seconds  两次决策之间的真实时间，默认 0.35
          --json path         把所有 BotReport 写成 JSON
          --verbose           每个种子打一行
          --seed S            只跑这一个种子，并打印逐决策轨迹
        """
    )
}

// MARK: - 日期

let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = PuzzleCalendar.timeZone
    return c
}()

func date(forDay day: String) -> Date? {
    let parts = day.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2])
    else { return nil }
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = dayOfMonth
    // 取正午，避开任何时区边界上的意外。
    components.hour = 12
    return calendar.date(from: components)
}

func day(_ base: String, offsetBy days: Int) -> String? {
    guard let start = date(forDay: base),
          let shifted = calendar.date(byAdding: .day, value: days, to: start)
    else { return nil }
    return PuzzleCalendar.dayString(for: shifted)
}

// MARK: - 统计

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let position = p * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, sorted.count - 1)
    let t = position - Double(lower)
    return sorted[lower] * (1 - t) + sorted[upper] * t
}

func mean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}

func fixed(_ x: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", x)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

// MARK: - 主流程

let options: Options
do {
    options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("plsbot: \(error)\n".utf8))
    printUsage()
    exit(2)
}

let resolver: ConfigResolver?
if let path = options.configPath {
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(Data("plsbot: \(CLIError.configUnreadable(path))\n".utf8))
        exit(2)
    }
    do {
        resolver = ConfigResolver(try RemoteConfig.decode(data))
    } catch {
        FileHandle.standardError.write(Data("plsbot: 配置解析失败 \(error)\n".utf8))
        exit(2)
    }
} else {
    resolver = nil
}

let today = PuzzleCalendar.dayString(for: Date())
let startDay = options.from ?? today
guard date(forDay: startDay) != nil else {
    FileHandle.standardError.write(Data("plsbot: --from \(startDay) 不是 yyyy-MM-dd\n".utf8))
    exit(2)
}

let botConfig = BotConfig(decisionInterval: options.interval)

func balance(for day: String) -> BalanceParams {
    resolver?.balance(for: day) ?? .default
}

func salt(for day: String) -> String {
    resolver?.seedSalt(for: day) ?? ""
}

// --seed：只跑一个种子，打印逐决策轨迹。
if let seed = options.singleSeed {
    let puzzle = PuzzleGenerator.generate(seed: seed, balance: balance(for: startDay))
    print("种子 \(seed)")
    print("  格子 \(puzzle.slots.map(\.rawValue).joined(separator: ","))")
    print("  键盘 \(puzzle.keys.map { "\($0.symbol)×\($0.uses)" }.joined(separator: " "))")
    print("  腐烂间隔 \(fixed(puzzle.rotInterval))s，时间上限 \(fixed(puzzle.runCapSeconds, 0))s")
    print("  奖励 \(puzzle.rewards.enumerated().map { "T\($0.offset + 1)=\(describe($0.element))" }.joined(separator: " "))")
    print("")
    print(pad("时钟", 8) + pad("动作", 22) + "当前值")
    // 连续的空转压成一行，不然阈值之间的等待会把轨迹淹掉。
    var waiting = 0
    var waitingFrom = 0.0
    func flushWaits() {
        guard waiting > 0 else { return }
        print(pad(fixed(waitingFrom), 8) + pad("wait ×\(waiting)", 22))
        waiting = 0
    }
    let report = GreedyBot.play(puzzle: puzzle, config: botConfig) { entry in
        if entry.action == "wait" {
            if waiting == 0 { waitingFrom = entry.rotClock }
            waiting += 1
            return
        }
        flushWaits()
        let value = entry.value.map { BigNumFormatter.string($0) } ?? "—"
        print(pad(fixed(entry.rotClock), 8) + pad(entry.action, 22) + value)
    }
    flushWaits()
    print("")
    print("峰值 \(BigNumFormatter.string(report.peak))  slog=\(fixed(report.peakSlog, 3))")
    print("跨档 \(report.tiersCrossed)，时间点 \(report.tierTimes.map { fixed($0, 1) }.joined(separator: ","))")
    print("按键 \(report.presses)，用时 \(fixed(report.runSeconds, 1))s，结束原因 \(report.endReason.rawValue)")
    print("结束时格子 \(report.slotKindsAtEnd.map(\.rawValue).joined(separator: ","))")
    print("结束时键盘 \(report.keysAtEnd.joined(separator: " "))")
    exit(0)
}

func describe(_ reward: Reward) -> String {
    switch reward {
    case .unlockKeys(let defs): return "解锁" + defs.map { "\($0.symbol)×\($0.uses)" }.joined(separator: "+")
    case .addSlot(let choices): return "加格(" + choices.map(\.rawValue).joined(separator: "/") + ")"
    case .convertSlot(let kind): return "改格(\(kind.rawValue))"
    case .repair(let amount): return "修键+\(amount)"
    case .freeze(let seconds): return "冻结\(fixed(seconds, 0))s"
    }
}

// 组装种子清单：先连续题日，再随机种子。
var jobs: [(seed: String, label: String)] = []
for offset in 0..<options.days {
    guard let d = day(startDay, offsetBy: offset) else { continue }
    jobs.append((PuzzleSeed.daily(day: d, salt: salt(for: d)), d))
}
for i in 0..<options.random {
    jobs.append(("PlsInput-random-\(i)", "random-\(i)"))
}

guard !jobs.isEmpty else {
    print("没有要跑的种子。")
    exit(0)
}

let started = Date()
var reports: [BotReport] = []
reports.reserveCapacity(jobs.count)
var labels: [String: String] = [:]
for job in jobs {
    let dayForBalance = job.label.hasPrefix("random-") ? startDay : job.label
    let puzzle = PuzzleGenerator.generate(seed: job.seed, balance: balance(for: dayForBalance))
    let report = GreedyBot.play(puzzle: puzzle, config: botConfig)
    labels[job.seed] = job.label
    reports.append(report)
    if options.verbose {
        print(
            pad(job.label, 14)
                + padLeft(BigNumFormatter.string(report.peak), 24)
                + padLeft("slog=" + fixed(report.peakSlog, 3), 16)
                + padLeft("T\(report.tiersCrossed)", 5)
                + padLeft("\(report.presses)按", 8)
                + padLeft(fixed(report.runSeconds, 1) + "s", 9)
                + "  " + report.endReason.rawValue
        )
    }
}
let elapsed = Date().timeIntervalSince(started)

// MARK: - JSON 输出

if let path = options.jsonPath {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let data = try encoder.encode(reports)
        try data.write(to: URL(fileURLWithPath: path))
        print("已写出 \(reports.count) 份报告到 \(path)")
    } catch {
        FileHandle.standardError.write(Data("plsbot: 写 JSON 失败 \(error)\n".utf8))
    }
}

// MARK: - 汇总报告

let slogs = reports.map(\.peakSlog).sorted()
let tierCount = 10

print("")
print("=== plsbot 校准报告 ===")
print("种子 \(reports.count) 个（每日 \(options.days) 天，起 \(startDay)；随机 \(options.random) 个），"
    + "决策间隔 \(fixed(options.interval))s，耗时 \(fixed(elapsed, 1))s")
print("")

print("峰值 slog10 分布：p10=\(fixed(percentile(slogs, 0.10), 3))  p50=\(fixed(percentile(slogs, 0.50), 3))  "
    + "p90=\(fixed(percentile(slogs, 0.90), 3))  max=\(fixed(slogs.last ?? 0, 3))")
let peakSorted = reports.sorted { $0.peakSlog < $1.peakSlog }
print("峰值示例：最低 \(BigNumFormatter.string(peakSorted.first?.peak ?? .zero))"
    + "，中位 \(BigNumFormatter.string(peakSorted[peakSorted.count / 2].peak))"
    + "，最高 \(BigNumFormatter.string(peakSorted.last?.peak ?? .zero))")
print("")

print("各档到达率：")
for tier in 0..<tierCount {
    let reached = reports.filter { $0.tiersCrossed > tier }
    let ratio = Double(reached.count) / Double(reports.count) * 100
    let times = reached.compactMap { $0.tierTimes.count > tier ? $0.tierTimes[tier] : nil }
    let bar = String(repeating: "█", count: Int((ratio / 2.5).rounded()))
    var line = "  T\(padLeft("\(tier + 1)", 2))  " + padLeft(fixed(ratio, 1) + "%", 7) + "  " + pad(bar, 42)
    if !times.isEmpty { line += " 均时 " + fixed(mean(times), 1) + "s" }
    print(line)
}
print("")

for tier in 0..<3 {
    let times = reports.compactMap { $0.tierTimes.count > tier ? $0.tierTimes[tier] : nil }
    let ratio = Double(times.count) / Double(reports.count) * 100
    print("到达 T\(tier + 1) 的平均腐烂时钟：" + (times.isEmpty ? "—" : fixed(mean(times), 2) + "s")
        + "（\(times.count) 个种子，\(fixed(ratio, 1))%）")
}
print("")

print("平均按键 \(fixed(mean(reports.map { Double($0.presses) }), 1))，"
    + "平均用时 \(fixed(mean(reports.map(\.runSeconds)), 1))s，"
    + "平均跨档 \(fixed(mean(reports.map { Double($0.tiersCrossed) }), 2))")

var reasons: [(EndReason, Int)] = []
for reason in [EndReason.keysExhausted, .playerEnded, .timeCap] {
    reasons.append((reason, reports.filter { $0.endReason == reason }.count))
}
print("结束原因：" + reasons.map { "\($0.0.rawValue) \($0.1)（\(fixed(Double($0.1) / Double(reports.count) * 100, 1))%）" }
    .joined(separator: "，"))
print("")

@MainActor func line(_ report: BotReport) -> String {
    let label = labels[report.seed] ?? report.seed
    return "  " + pad(label, 14)
        + padLeft(BigNumFormatter.string(report.peak), 26)
        + padLeft("slog=" + fixed(report.peakSlog, 3), 16)
        + padLeft("T\(report.tiersCrossed)", 5)
        + padLeft(fixed(report.runSeconds, 1) + "s", 9)
        + "  " + report.endReason.rawValue
}

print("峰值最低的 10 个种子：")
for report in peakSorted.prefix(10) { print(line(report)) }
print("")
print("峰值最高的 10 个种子：")
for report in peakSorted.suffix(10).reversed() { print(line(report)) }
print("")

let suspects = reports.filter { $0.tiersCrossed < 3 || $0.runSeconds < 30 }
let stuckAtStart = reports.filter { $0.tiersCrossed < 3 }
let tooShort = reports.filter { $0.runSeconds < 30 }
print("坏题嫌疑（没到 T3 或不足 30 秒就结束）：\(suspects.count) 个"
    + "（\(fixed(Double(suspects.count) / Double(reports.count) * 100, 1))%）"
    + "；其中没到 T3 的 \(stuckAtStart.count) 个，不足 30 秒的 \(tooShort.count) 个，"
    + "只跨到 T1 就卡死的 \(reports.filter { $0.tiersCrossed == 1 }.count) 个")
for report in suspects.sorted(by: { $0.peakSlog < $1.peakSlog }).prefix(30) {
    let label = labels[report.seed] ?? report.seed
    print("  " + pad(label, 14)
        + padLeft(BigNumFormatter.string(report.peak), 26)
        + padLeft("T\(report.tiersCrossed)", 5)
        + padLeft(fixed(report.runSeconds, 1) + "s", 9)
        + padLeft("\(report.presses)按", 8)
        + "  " + report.endReason.rawValue
        + "  键 " + report.keysAtEnd.joined(separator: "")
        + "  格 " + report.slotKindsAtEnd.map { String($0.rawValue.prefix(2)) }.joined(separator: ","))
}
if suspects.count > 30 { print("  …… 其余 \(suspects.count - 30) 个略") }

exit(0)

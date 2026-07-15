import SwiftUI
import Charts
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Cross-Device HRV
//
// A wearer who has worn more than one HRV sensor over time (e.g. years of Oura ring history
// continuing onto a WHOOP strap) has two INCOMPATIBLE RMSSD scales with no overlap night to
// calibrate against — Oura reads ~120-155 ms, WHOOP ~72-112 ms. Averaging them is dishonest;
// showing only the current strap throws away the long trend the wearer cares about.
//
// This screen resolves that for a DISPLAY/trend lens (daily 0-3 scores stay strictly per-device
// via deviceEraEpoch): every night is measured against its OWN device-era's robust log-scale
// centre, so the era-relative trend flows continuously across the switch — you can see whether
// HRV was trending up or down THROUGH the hardware change — while a second, raw chart keeps each
// sensor's true milliseconds. All math is the pure, DB-free `CrossDeviceHRVTrend` engine.

struct CrossDeviceHRVView: View {
    @EnvironmentObject var repo: Repository

    /// One night, parsed to a `Date` once so the chart never re-parses "yyyy-MM-dd" on body re-eval.
    private struct Row: Identifiable {
        let id: String        // the day key — stable + unique per night
        let date: Date
        let raw: Double       // absolute ms as the device reported it
        let pct: Double       // % above/below this device-era's own centre
        let brand: String     // "oura" / "whoop" / …
        let isEraStart: Bool  // first night of a non-first era = a device switch
    }

    @State private var eras: [CrossDeviceHRVTrend.Era] = []
    @State private var rows: [Row] = []          // all nights, one continuous series (hero)
    @State private var segments: [[Row]] = []    // nights grouped per era (raw, scale-honest)
    @State private var latestNight: Repository.NightHRV?   // dual-metric header + Apple cross-check
    @State private var loaded = false

    var body: some View {
        ScreenScaffold(title: "Cross-Device HRV",
                       subtitle: "Your full HRV history, stitched across a device switch") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                } else {
                    latestNightSection
                    if rows.count >= 2 {
                        heroTrend
                        rawTrend
                        eraLegend
                        methodology
                    } else if latestNight == nil {
                        emptyCard
                    }
                }
            }
        }
        .task { await load() }
    }

    // MARK: 0 · Latest night — both HRV metrics, labeled (+ Apple cross-check)

    @ViewBuilder private var latestNightSection: some View {
        if let n = latestNight, n.rmssd != nil || n.sdnn != nil {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Latest Night", overline: "Both HRV metrics, labeled", trailing: prettyDay(n.day))
                NoopCard(tint: StrandPalette.metricPurple) {
                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        HStack(alignment: .top, spacing: 0) {
                            metricColumn("RMSSD", n.rmssd, "beat-to-beat · vagal", StrandPalette.metricPurple)
                            Divider().frame(height: 46).overlay(StrandPalette.hairline)
                            metricColumn("SDNN", n.sdnn, "5-min index · overall", StrandPalette.metricCyan)
                        }
                        if let local = n.sdnn, let apple = n.appleSdnn, apple > 0 {
                            Divider().overlay(StrandPalette.hairline)
                            appleCrossCheck(local: local, apple: apple)
                        }
                        Text("RMSSD tracks fast vagal (parasympathetic) tone; SDNN captures overall variability. Both are computed from the same night's beats — different lenses, not different data — so they're no longer collapsed into one ambiguous \u{201C}HRV\u{201D} number.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func metricColumn(_ label: LocalizedStringKey, _ value: Double?, _ caption: String,
                              _ accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text(value.map { "\(Int($0.rounded())) ms" } ?? "—")
                .font(StrandFont.title2)
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : accent)
            Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    private func appleCrossCheck(local: Double, apple: Double) -> some View {
        let deltaPct = Int(((local - apple) / apple * 100).rounded())
        return VStack(alignment: .leading, spacing: 3) {
            Text("Apple Watch cross-check").strandOverline()
            HStack {
                Text("NOOP 5-min SDNN \(Int(local.rounded())) ms")
                Spacer()
                Text("Apple \(Int(apple.rounded())) ms")
            }
            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("\(deltaPct >= 0 ? "+" : "")\(deltaPct)% vs your watch — both are short-window SDNN (NOOP over 5-min segments, Apple ~1-min), so NOOP's usually reads a little higher but tracks the same nightly moves.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 1 · Era-relative long-term trend (the continuous shape across the switch)

    private var heroTrend: some View {
        let boundaries = rows.filter { $0.isEraStart }
        // Robust symmetric Y-bound: the era-relative % is a log-ratio, so a known Oura nap-fragment
        // artifact (an overnight "HRV" of ~12 ms against a ~135 ms normal) reads as −240%+ and would
        // auto-stretch the axis until the real ±20-40% trend collapses to a flat line. Scale to the 90th
        // percentile of |deviation| (padded), clamped to a readable band; genuine outliers clip cleanly.
        let absPcts = rows.map { abs($0.pct) }.sorted()
        let p90 = absPcts.isEmpty ? 40 : absPcts[min(absPcts.count - 1, Int(Double(absPcts.count) * 0.90))]
        let heroBound = min(75, max(25, (p90 * 1.3).rounded()))
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Long-Term Trend", overline: "Stitched across devices",
                          trailing: "\(rows.count) nights")
            NoopCard(tint: StrandPalette.metricPurple) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text("HRV vs each device-era's own normal").strandOverline()
                    Chart {
                        RuleMark(y: .value("Normal", 0))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(StrandPalette.textTertiary.opacity(0.6))
                        ForEach(rows) { row in
                            LineMark(x: .value("Date", row.date),
                                     y: .value("Relative", row.pct))
                                .interpolationMethod(.catmullRom)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(StrandPalette.metricPurple)
                        }
                        ForEach(boundaries) { b in
                            RuleMark(x: .value("Switch", b.date))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .foregroundStyle(brandColor(b.brand).opacity(0.7))
                                .annotation(position: .top, alignment: .center, spacing: 2) {
                                    Text("→ \(brandLabel(b.brand))")
                                        .font(StrandFont.footnote)
                                        .foregroundStyle(brandColor(b.brand))
                                }
                        }
                    }
                    .frame(height: NoopMetrics.chartHeight)
                    .chartYScale(domain: -heroBound...heroBound)
                    .chartPlotStyle { $0.clipped() }
                    .chartXAxis { dateAxis }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                            AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                            AxisValueLabel {
                                if let pct = value.as(Double.self) {
                                    Text("\(pct > 0 ? "+" : "")\(Int(pct))%")
                                }
                            }
                            .foregroundStyle(StrandPalette.textTertiary)
                            .font(StrandFont.footnote)
                        }
                    }
                    Text("Each sensor is compared to its own baseline, so the trend's shape carries across your switch even though the raw numbers differ. The dashed line is each era's normal.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 2 · Raw nightly HRV (scale-honest, per device)

    private var rawTrend: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Raw Nightly HRV", overline: "Scale-honest per device")
            NoopCard(tint: StrandPalette.metricCyan) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text("Actual milliseconds, never averaged").strandOverline()
                    Chart {
                        ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                            ForEach(seg) { row in
                                LineMark(x: .value("Date", row.date),
                                         y: .value("HRV", row.raw),
                                         series: .value("Era", idx))
                                    .interpolationMethod(.catmullRom)
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                                    .foregroundStyle(brandColor(row.brand))
                            }
                        }
                    }
                    .frame(height: NoopMetrics.chartHeight)
                    .chartPlotStyle { $0.clipped() }
                    .chartXAxis { dateAxis }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                            AxisValueLabel().foregroundStyle(StrandPalette.textTertiary).font(StrandFont.footnote)
                        }
                    }
                    Text("Oura and WHOOP measure HRV on different scales, so the two eras sit at different heights — that gap is real, not a change in you. We keep each sensor's true numbers instead of blending them.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 3 · Era legend

    private var eraLegend: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Devices", overline: "Eras")
            NoopCard(tint: StrandPalette.accent) {
                VStack(spacing: NoopMetrics.cardInnerSpacing) {
                    ForEach(Array(eras.enumerated()), id: \.offset) { idx, era in
                        HStack(spacing: 10) {
                            Circle().fill(brandColor(era.brand)).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(brandLabel(era.brand))
                                    .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                Text("\(monthYear(era.startDay)) – \(monthYear(era.endDay)) · \(era.nights) nights")
                                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(Int(era.centerMs.rounded())) ms")
                                    .font(StrandFont.body).foregroundStyle(brandColor(era.brand))
                                Text("typical").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        if idx < eras.count - 1 { Divider().overlay(StrandPalette.hairline) }
                    }
                }
            }
        }
    }

    // MARK: 4 · Methodology

    private var methodology: some View {
        NoopCard(tint: StrandPalette.metricPurple) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("How this is stitched").strandOverline()
                Text("You've worn more than one HRV sensor. Different sensors report HRV on different scales, and there's no night where both were worn to line them up — so any single blended number would be fiction.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Instead, each night is measured against its own device-era's normal (a robust log-scale centre). Plotting that relative view lets the long-term trend flow continuously across the switch, while the raw chart keeps each sensor's true milliseconds. Your daily readiness and stress scores stay strictly per-device.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyCard: some View {
        NoopCard(tint: StrandPalette.metricPurple) {
            Text("Not enough HRV history yet to stitch a cross-device trend. Keep wearing your strap, or import a prior device's history.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Shared axis / brand helpers

    private var dateAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
            AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                .foregroundStyle(StrandPalette.textTertiary).font(StrandFont.footnote)
        }
    }

    private func brandColor(_ brand: String) -> Color {
        switch brand {
        case "oura":   return StrandPalette.metricCyan
        case "whoop":  return StrandPalette.metricPurple
        case "fitbit": return StrandPalette.metricAmber
        case "garmin": return StrandPalette.chargeColor
        default:       return StrandPalette.accent
        }
    }

    private func brandLabel(_ brand: String) -> String {
        switch brand {
        case "oura":   return "Oura"
        case "whoop":  return "WHOOP"
        case "fitbit": return "Fitbit"
        case "garmin": return "Garmin"
        default:       return brand.capitalized
        }
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static let monthYearFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private func monthYear(_ day: String) -> String {
        guard let d = Self.dayParser.date(from: day) else { return day }
        return Self.monthYearFmt.string(from: d)
    }
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private func prettyDay(_ day: String) -> String {
        guard let d = Self.dayParser.date(from: day) else { return day }
        return Self.dayFmt.string(from: d)
    }

    // MARK: - Load

    private func load() async {
        let history = await repo.crossDeviceHrvHistory()
        let result = CrossDeviceHRVTrend.build(history)
        let parsed: [Row] = result.points.map { p in
            Row(id: p.day, date: Self.dayParser.date(from: p.day) ?? Date(timeIntervalSince1970: 0),
                raw: p.raw, pct: p.eraRelativePct, brand: p.brand, isEraStart: p.isEraStart)
        }
        // Group into per-era segments (a device switch opens a new segment).
        var segs: [[Row]] = []; var cur: [Row] = []
        for row in parsed {
            if row.isEraStart && !cur.isEmpty { segs.append(cur); cur = [] }
            cur.append(row)
        }
        if !cur.isEmpty { segs.append(cur) }

        let night = await repo.latestNightHRV()

        self.eras = result.eras
        self.rows = parsed
        self.segments = segs
        self.latestNight = night
        self.loaded = true
    }
}

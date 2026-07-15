import Foundation

/// Cross-device HRV long-term trend — stitch a wearer's full nightly HRV history across a device switch
/// (e.g. a 2-year Oura ring history continuing onto a WHOOP strap) into ONE continuous long-term view,
/// WITHOUT falsely claiming two brands' incompatible RMSSD scales are the same number (Oura RMSSD
/// ~120–155 ms vs WHOOP ~72–112 ms, with no overlap nights to calibrate against — see
/// `Baselines.deviceEraEpoch`, #459).
///
/// The honest resolution: each night carries BOTH its RAW value (what that device actually measured) and
/// an ERA-RELATIVE % (how far it sits above/below that device-era's own robust centre). Plotting the
/// era-relative series gives a continuous trend SHAPE across the switch — the Oura decline flows straight
/// into the WHOOP era — while the raw series stays scale-honest per device and boundaries are marked so the
/// user knows the sensor changed. This is a DISPLAY/trend lens only; the 0–3 scores stay strictly
/// per-device (via `deviceEraEpoch`). Pure, deterministic, DB-free.
public enum CrossDeviceHRVTrend {

    /// One night on the stitched trend.
    public struct Point: Equatable, Sendable {
        /// "yyyy-MM-dd".
        public let day: String
        /// Absolute nightly HRV (ms) exactly as this device reports it — scale differs across eras.
        public let raw: Double
        /// % above/below this device-era's own robust (median-of-ln) centre. Cross-era comparable in
        /// SHAPE (not absolute level), so the long trend reads continuously through the switch.
        public let eraRelativePct: Double
        /// Coarse HRV-scale brand ("oura"/"whoop"/…) via `Baselines.brandBucket` — the era this night is in.
        public let brand: String
        /// True on the first night of a NON-FIRST era — i.e. a device switch — so the UI can draw a
        /// boundary marker ("switched to WHOOP"). Never true for the very first era's first night.
        public let isEraStart: Bool

        public init(day: String, raw: Double, eraRelativePct: Double, brand: String, isEraStart: Bool) {
            self.day = day; self.raw = raw; self.eraRelativePct = eraRelativePct
            self.brand = brand; self.isEraStart = isEraStart
        }
    }

    /// A contiguous single-brand stretch of the history, with its own centre — the unit the trend
    /// normalises against, and what a UI legend/segment can label ("Oura · 408 nights").
    public struct Era: Equatable, Sendable {
        public let brand: String
        public let startDay: String
        public let endDay: String
        public let nights: Int
        /// Geometric (median-of-ln) centre HRV of the era, in ms.
        public let centerMs: Double
        public init(brand: String, startDay: String, endDay: String, nights: Int, centerMs: Double) {
            self.brand = brand; self.startDay = startDay; self.endDay = endDay
            self.nights = nights; self.centerMs = centerMs
        }
    }

    public struct Result: Equatable, Sendable {
        public let points: [Point]
        public let eras: [Era]
        public init(points: [Point], eras: [Era]) { self.points = points; self.eras = eras }
    }

    /// Build the continuous cross-device trend from source-tagged nightly HRV — one WINNING source per
    /// day (the same per-day merge winner the fold uses; NOT one row per source — mirrors the
    /// `deviceEraEpoch` contract). Any order; sorted here. Nights are grouped into CONTIGUOUS single-brand
    /// eras (a device switch opens a new era); each era normalises against the median of its own ln(HRV).
    /// Single-brand history → one era, every `eraRelativePct` vs that one centre (still valid). Empty → empty.
    public static func build(_ sourceDays: [(day: String, sourceId: String, hrv: Double)]) -> Result {
        let sorted = sourceDays.filter { $0.hrv > 0 }
            .sorted { $0.day != $1.day ? $0.day < $1.day : $0.sourceId < $1.sourceId }
        guard !sorted.isEmpty else { return Result(points: [], eras: []) }

        // Segment into contiguous same-brand eras.
        var eraRows: [[(day: String, sourceId: String, hrv: Double)]] = []
        var cur: [(day: String, sourceId: String, hrv: Double)] = []
        var curBrand: String? = nil
        for row in sorted {
            let b = Baselines.brandBucket(row.sourceId)
            if let cb = curBrand, cb != b { eraRows.append(cur); cur = [] }
            curBrand = b
            cur.append(row)
        }
        if !cur.isEmpty { eraRows.append(cur) }

        var points: [Point] = []
        var eras: [Era] = []
        for (ei, era) in eraRows.enumerated() {
            let brand = Baselines.brandBucket(era[0].sourceId)
            let centerLn = median(era.map { log($0.hrv) })
            eras.append(Era(brand: brand, startDay: era.first!.day, endDay: era.last!.day,
                            nights: era.count, centerMs: exp(centerLn)))
            for (i, row) in era.enumerated() {
                points.append(Point(day: row.day, raw: row.hrv,
                                    eraRelativePct: (log(row.hrv) - centerLn) * 100.0,
                                    brand: brand,
                                    isEraStart: ei > 0 && i == 0))
            }
        }
        return Result(points: points, eras: eras)
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted(); let n = s.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}

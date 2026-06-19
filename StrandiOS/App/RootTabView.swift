#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
struct RootTabView: View {
    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// Selected tab — bound so tab switches can crossfade (README §Motion: ~240ms opacity swap
    /// between tab roots, calm easing). Defaults to Today.
    @State private var selectedTab: Int = 0

    init() {
        // Plain Titanium bar: pin the background to `surfaceBase` and clear the system
        // selection-indicator tint so there is NO gold/accent pill behind the selected
        // icon — the gold `.tint` below colours only the selected icon + label, nothing
        // is filled behind it. (UIKit derives a selection-indicator fill from the tint
        // unless it's explicitly cleared.)
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(StrandPalette.surfaceBase)
        appearance.selectionIndicatorTintColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        // The native TabView keeps every existing destination + system gesture; the signature
        // raised gold FAB is overlaid on top, bottom-centre, floating ~20pt above the bar (a
        // native TabView can't host a centre item that overflows the bar, so we float it).
        ZStack(alignment: .bottom) {
            // A custom floating bar — two frosted "glass" islands with the gold action button nested
            // cleanly in the gap between them — replaces the native tab bar: no overlap, no glow. The
            // native TabView still drives content + per-tab nav state; only its bar is hidden.
            TabView(selection: $selectedTab) {
                tab(TodayView(), "Today", "square.grid.2x2").tag(0)
                tab(TrendsView(), "Trends", "chart.line.uptrend.xyaxis").tag(1)
                tab(SleepView(), "Sleep", "bed.double").tag(2)
                moreTab.tag(3)
            }
            .tint(StrandPalette.accent)
            .toolbar(.hidden, for: .tabBar)
            // Tab crossfade — README §Motion: ~240ms opacity swap between tab roots, global calm
            // easing cubic-bezier(0.22,1,0.36,1).
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)

            FloatingTabBar(selection: $selectedTab)
        }
        .task { await repo.refresh() }
        // Quick-action sheet presents with the calm easing (~0.42s) per the README sheet spec —
        // the easing is applied where `quickAction` is set (see `presentQuickAction`), keeping the
        // animation scoped to the sheet rather than the whole shell.
        .sheet(item: $quickAction) { action in
            quickActionDestination(action)
        }
        // Live's "Manage devices" affordance (and any future cross-screen link to Devices) routes here:
        // present the Devices manager in its own nav stack, the same way the quick-action screens do.
        .sheet(isPresented: $showDevices) {
            devicesScreen
        }
        // v5 pillar deep-links (Insights hub / Lab Book / fused record / Rhythm) present as a sheet in
        // their own nav stack — the same idiom the quick-action + Devices screens use on iPhone.
        .sheet(item: $routedPillar) { dest in
            pillarScreen(dest)
        }
        // Honour a router request: Devices keeps its dedicated sheet; the v5 pillars route through the
        // shared pillar sheet. Cleared so the same tap can fire again later.
        .onChange(of: router.requestedDestination) { _, dest in
            switch dest {
            case .devices:
                showDevices = true
                router.requestedDestination = nil
            case .insightsHub, .labBook, .fusedRecord, .rhythm:
                routedPillar = dest
                router.requestedDestination = nil
            case .trends:
                // Trends is a primary tab on iPhone (not a pillar sheet) — switch to it.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 1 }
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        // A screen's top-bar "+" routes here: open the quick-action sheet, then clear the flag.
        .onChange(of: router.quickActionsRequested) { _, req in
            if req {
                withAnimation(Self.sheetEase) { quickAction = .menu }
                router.quickActionsRequested = false
            }
        }
    }

    /// A routed v5 pillar screen wrapped in its own nav stack + Done button (mirrors `quickScreen`).
    @ViewBuilder
    private func pillarScreen(_ dest: NavRouter.Destination) -> some View {
        NavigationStack {
            Group {
                switch dest {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                case .devices: DevicesView()
                // .trends is never presented as a pillar sheet on iPhone (it's a primary tab — the
                // requestedDestination handler switches `selectedTab` instead), but the switch must stay
                // exhaustive. Fall back to Trends inside the sheet host if it ever arrives here.
                case .trends: TrendsView()
                }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routedPillar = nil }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    /// Calm-easing curve (cubic-bezier(0.22,1,0.36,1)) at the README sheet-present duration.
    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // MARK: - Quick-action sheet

    /// Routes a chosen quick action to the existing screen, or shows the action menu itself.
    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            QuickActionSheet { picked in
                // Swap the menu for the chosen destination on the next runloop so the sheet
                // re-presents cleanly (avoids dismiss/re-present races). Calm easing on re-present.
                quickAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(Self.sheetEase) { quickAction = picked }
                }
            }
            .presentationDetents([.height(344)])
            .presentationDragIndicator(.hidden)
        case .live:
            quickScreen(LiveView())
        case .workout:
            quickScreen(WorkoutsView())
        case .journal:
            quickScreen(InsightsView())
        case .breathe:
            quickScreen(BreathingView())
        }
    }

    /// Wraps a routed quick-action screen in its own nav stack so it has a title bar + the
    /// shared surface background, matching how the More-tab links present these same views.
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    /// The Devices manager wrapped in its own nav stack + Done button (mirrors `quickScreen`, but
    /// dismisses the dedicated `showDevices` sheet rather than the quick-action item).
    private var devicesScreen: some View {
        NavigationStack {
            DevicesView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showDevices = false }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String) -> some View {
        view
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar(.hidden, for: .tabBar)   // we draw our own FloatingTabBar
            .tabItem { Label(title, systemImage: icon) }
    }

    private var moreTab: some View {
        NavigationStack {
            List {
                Section("Insights") {
                    link("What Moves You", "wand.and.sparkles") { InsightsHubView() }
                    link("Intelligence", "brain.head.profile") { IntelligenceView() }
                    link("Coach", "sparkles") { CoachView() }
                    link("Insights", "lightbulb.fill") { InsightsView() }
                    link("Explore", "square.grid.2x2.fill") { MetricExplorerView() }
                    link("Compare", "rectangle.split.2x1.fill") { CompareView() }
                }
                Section("Body") {
                    link("Live", "waveform.path.ecg") { LiveView() }
                    link("Workouts", "figure.run") { WorkoutsView() }
                    link("Health", "heart.text.square.fill") { HealthView() }
                    link("Lab Book", "books.vertical.fill") { LabBookView() }
                    link("Stress", "bolt.heart.fill") { StressView() }
                    link("Breathe", "wind") { BreathingView() }
                    link("Intervals", "timer") { IntervalTimerView() }
                    // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
                    link("Rhythm", "waveform.path") { RhythmHost() }
                }
                Section("Data") {
                    link("Your Data, Fused", "square.stack.3d.up.fill") { FusedRecordHost() }
                    link("Apple Health", "heart.fill") { AppleHealthView() }
                    link("Mi Band", "figure.walk.motion") { XiaomiBandView() }
                    link("Data Sources", "externaldrive.fill") { DataSourcesView() }
                    // #155: HealthKit-free Apple Health path for sideloaded installs (Siri Shortcut
                    // reads the opt-in Documents/noop_sync.txt drop file).
                    link("Shortcuts Export", "square.and.arrow.up.fill") { ShortcutExportSettingsView() }
                }
                Section("App") {
                    link("Automations", "wand.and.stars") { AutomationsView() }
                    link("Siri & Shortcuts", "mic.fill") { SiriShortcutsSettingsView() }
                    link("Settings", "gearshape.fill") { SettingsView() }
                    link("Support", "hands.clap.fill") { SupportView() }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("More")
            .toolbar(.hidden, for: .tabBar)   // we draw our own FloatingTabBar
        }
        .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
    }

    private func link<V: View>(_ title: LocalizedStringKey, _ icon: String, @ViewBuilder _ dest: @escaping () -> V) -> some View {
        NavigationLink {
            dest()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(StrandPalette.surfaceBase, for: .navigationBar)
        } label: {
            // Pin the icon to the accent explicitly. A plain `Label(_:systemImage:)` icon inherits the
            // list's tint, which iOS re-resolves to its default blue a beat after first render — so the
            // icons flashed green→blue (#184). An explicit foregroundStyle on the image overrides that;
            // the title keeps its default (primary) colour.
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon).foregroundStyle(StrandPalette.accent)
            }
        }
        .listRowBackground(StrandPalette.surfaceRaised)
    }
}

// MARK: - Quick actions (centre FAB)

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
private enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe
    var id: Int { rawValue }
}

/// The bottom sheet of quick actions presented by the centre FAB. Spec bottom sheet: surfaceOverlay
/// fill, gold hairline top edge, grab handle, three flat action rows that route to existing screens.
private struct QuickActionSheet: View {
    /// Called with the picked destination (the host swaps the menu for that screen).
    let onPick: (QuickAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle (36×4) in the slate hairline tone.
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("QUICK ACTIONS")
                .font(StrandFont.overline)
                .tracking(1.6)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                row("Live HR", icon: "waveform.path.ecg", tint: StrandPalette.metricRose) { onPick(.live) }
                row("Start workout", icon: "figure.run", tint: StrandPalette.effortColor) { onPick(.workout) }
                row("Log journal", icon: "square.and.pencil", tint: StrandPalette.accent) { onPick(.journal) }
                row("Breathe", icon: "wind", tint: StrandPalette.restColor) { onPick(.breathe) }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            StrandPalette.surfaceOverlay
                .overlay(alignment: .top) {
                    // Gold hairline top edge per the bottom-sheet spec.
                    Rectangle()
                        .fill(StrandPalette.gold.opacity(0.35))
                        .frame(height: 1)
                }
                .ignoresSafeArea()
        )
    }

    /// One flat action row: hued line-icon tile + title, inset surface, hairline border.
    private func row(_ title: LocalizedStringKey, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(StrandPalette.surfaceInset))
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Floating tab bar

/// The signature bottom bar: two frosted "glass" islands (Today·Trends / Sleep·More) with the gold
/// action button nested cleanly in the gap between them — no overlap, no glow. Real iOS 26 Liquid
/// Glass where available, a `.ultraThinMaterial` fallback below. Replaces the hidden native tab bar.
private struct FloatingTabBar: View {
    @Binding var selection: Int

    private struct Item: Identifiable { let title: LocalizedStringKey; let icon: String; let tag: Int; var id: Int { tag } }
    private let nav = [Item(title: "Today", icon: "square.grid.2x2", tag: 0),
                       Item(title: "Trends", icon: "chart.line.uptrend.xyaxis", tag: 1),
                       Item(title: "Sleep", icon: "bed.double", tag: 2),
                       Item(title: "More", icon: "ellipsis", tag: 3)]

    var body: some View {
        // One frosted glass bar, four evenly-spaced tabs. The quick-action "+" now lives in the
        // top-right of each screen's header (balancing the profile avatar on the left).
        HStack(spacing: 2) {
            tabButton(nav[0])
            tabButton(nav[1])
            tabButton(nav[2])
            tabButton(nav[3])
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .liquidGlass(in: Capsule())
        .overlay(Capsule().strokeBorder(StrandPalette.hairline.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 5)
        .padding(.horizontal, 22)
        .padding(.bottom, 4)
    }

    private func tabButton(_ item: Item) -> some View {
        let active = selection == item.tag
        return Button {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selection = item.tag }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: active ? .semibold : .regular))
                Text(item.title)
                    .font(.system(size: 10, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? StrandPalette.accent : StrandPalette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

}

// MARK: - Liquid Glass (iOS 26) with a Material fallback

private extension View {
    /// Real iOS 26 Liquid Glass where available; `.ultraThinMaterial` on iOS 17–25 — a clean
    /// blended degrade so the bar stays modern on new OSes without breaking older ones.
    @ViewBuilder func liquidGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
#endif

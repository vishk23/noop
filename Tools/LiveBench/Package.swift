// swift-tools-version:5.9
import PackageDescription

// LiveBench — an offline scoring harness for the CAUSAL sleep stager.
//
// `Tools/SleepBench` replays the post-hoc stagers (V1/V2) and scores them against the references a NOOP
// database carries. This tool asks the two questions SleepBench structurally cannot: does
// `LiveSleepStager` ever read the future (truncation invariance), and how long AFTER a REM period begins
// does its posterior cross a cue threshold. It also re-states, from the data rather than from a comment,
// which references in that database can serve as a REM ground truth — the answer today is none.
//
// The database path is ALWAYS a command-line argument. No health data lives in this repository, none is
// written back, and the file is opened READONLY + `immutable=1`.
let package = Package(
    name: "livebench",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../Packages/StrandAnalytics"),
        .package(path: "../../Packages/WhoopProtocol"),
    ],
    targets: [
        .executableTarget(name: "livebench", dependencies: ["StrandAnalytics", "WhoopProtocol"]),
    ]
)

# Helper Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep 30-second broad-route protection while moving full route reconciliation to five minutes and preventing status or shell commands from wedging the helper.

**Architecture:** `MonitorLoop` retains one timer but delegates the full-refresh decision to a pure schedule type. `HelperTool` replies from cached status and coalesces live probes on a utility queue. `ShellRunner` owns the one bounded subprocess lifecycle used by every helper caller.

**Tech Stack:** Swift 5.9+, Foundation `Process`, Grand Central Dispatch, XCTest, XcodeGen, Xcode 16+

## Global Constraints

- Keep the 30-second broad-route sweep.
- Reconcile full DNS/custom/bypass routes every 300 seconds and immediately on startup or forced refresh.
- Keep the app's five-second status polling and XPC timeout.
- Add no dependency and no new OS watcher.
- Preserve `split-shield-icon.svg` untracked.
- Commit locally with signed, conventional, single-line commits; never push.

---

### Task 1: Bound helper subprocesses

**Files:**
- Modify: `macOS/ZscalerSplitTunnelHelper/ShellRunner.swift`
- Create: `macOS/ZscalerSplitTunnelHelperTests/ShellRunnerTests.swift`

**Interfaces:**
- Produces: `ShellRunner.timeoutExitCode`, plus an optional `timeout: TimeInterval` argument on `run`, `runSilent`, and `runCapturingStderr`.
- Default timeout: 10 seconds; termination grace: 1 second.

- [ ] **Step 1: Write failing timeout tests**

```swift
import XCTest

final class ShellRunnerTests: XCTestCase {
    func testRunTimesOut() {
        let started = Date()
        let result = ShellRunner.run("/bin/sleep", arguments: ["2"], timeout: 0.1)
        XCTAssertEqual(result.exitCode, ShellRunner.timeoutExitCode)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testRunSilentTimesOut() {
        XCTAssertEqual(
            ShellRunner.runSilent("/bin/sleep", arguments: ["2"], timeout: 0.1),
            ShellRunner.timeoutExitCode
        )
    }

    func testRunCapturingStderrTimesOutWithoutLosingOutput() {
        let result = ShellRunner.runCapturingStderr(
            "/bin/sh",
            arguments: ["-c", "printf stdout; printf stderr >&2; sleep 2"],
            timeout: 0.1
        )
        XCTAssertEqual(result.exitCode, ShellRunner.timeoutExitCode)
        XCTAssertEqual(result.stdout, "stdout")
        XCTAssertEqual(result.stderr, "stderr")
    }
}
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
cd macOS
xcodebuild test -project ZscalerSplitTunnel.xcodeproj \
  -scheme ZscalerSplitTunnelHelperTests \
  -destination 'platform=macOS' \
  -only-testing:ZscalerSplitTunnelHelperTests/ShellRunnerTests
```

Expected: compile failure because the timeout API and `timeoutExitCode` do not exist.

- [ ] **Step 3: Implement one bounded process lifecycle**

Replace the three duplicated launch/wait paths with one private runner. The implementation must:

```swift
static let timeoutExitCode: Int32 = 124
private static let defaultTimeout: TimeInterval = 10
private static let terminationGrace: TimeInterval = 1

private struct Result {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private static func execute(
    _ executablePath: String,
    arguments: [String],
    captureStdout: Bool,
    captureStderr: Bool,
    timeout: TimeInterval
) -> Result
```

Set `Process.terminationHandler` before `run()`, drain requested pipes concurrently, wait on a semaphore until the deadline, send `terminate()`, then `kill(pid, SIGKILL)` after the one-second grace. Return exit code 124 on timeout and preserve captured output. The public methods only map this shared result to their existing return shapes.

- [ ] **Step 4: Verify GREEN and the complete helper test scheme**

Run the focused command from Step 2, then:

```bash
cd macOS
xcodebuild test -project ZscalerSplitTunnel.xcodeproj \
  -scheme ZscalerSplitTunnelHelperTests \
  -destination 'platform=macOS'
```

Expected: all helper tests pass with zero failures.

- [ ] **Step 5: Commit**

```bash
git status --short
git add macOS/ZscalerSplitTunnelHelper/ShellRunner.swift \
  macOS/ZscalerSplitTunnelHelperTests/ShellRunnerTests.swift
git commit -m "fix(helper): bound shell commands"
```

### Task 2: Make status replies snapshot-only

**Files:**
- Create: `macOS/ZscalerSplitTunnelHelper/HelperStatusCache.swift`
- Create: `macOS/ZscalerSplitTunnelHelperTests/HelperStatusCacheTests.swift`
- Modify: `macOS/ZscalerSplitTunnelHelper/HelperTool.swift`
- Modify: `macOS/project.yml`
- Modify mechanically: `macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `LiveHelperStatus`, `HelperStatusCache.snapshotAndBeginRefresh()`, and `HelperStatusCache.finishRefresh(_:)`.
- `getStatus` consumes the latest `LiveHelperStatus`, replies immediately, then schedules at most one background refresh.

- [ ] **Step 1: Write the failing cache/coalescing test**

```swift
import XCTest

final class HelperStatusCacheTests: XCTestCase {
    func testReturnsLatestSnapshotAndCoalescesRefreshes() {
        let cache = HelperStatusCache()
        let first = cache.snapshotAndBeginRefresh()
        XCTAssertTrue(first.shouldRefresh)
        XCTAssertFalse(first.snapshot.zscalerRunning)

        XCTAssertFalse(cache.snapshotAndBeginRefresh().shouldRefresh)

        cache.finishRefresh(LiveHelperStatus(
            zscalerRunning: true,
            zscalerInterface: "utun4",
            broadIPv4: 0,
            broadIPv6: 0,
            networkSignature: "192.168.0.1|en0|192.168.0.10"
        ))

        let refreshed = cache.snapshotAndBeginRefresh()
        XCTAssertTrue(refreshed.shouldRefresh)
        XCTAssertTrue(refreshed.snapshot.zscalerRunning)
        XCTAssertEqual(refreshed.snapshot.zscalerInterface, "utun4")
    }
}
```

- [ ] **Step 2: Add the new production file to both helper targets and verify RED**

Add `ZscalerSplitTunnelHelper/HelperStatusCache.swift` to the `ZscalerSplitTunnelHelperTests.sources` list in `macOS/project.yml`, run `xcodegen generate` from `macOS/`, then run only `HelperStatusCacheTests`.

Expected: compile failure because the cache types do not exist.

- [ ] **Step 3: Implement the lock-protected cache**

```swift
struct LiveHelperStatus: Sendable {
    var zscalerRunning = false
    var zscalerInterface: String?
    var broadIPv4 = 0
    var broadIPv6 = 0
    var networkSignature: String?
}

final class HelperStatusCache: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = LiveHelperStatus()
    private var refreshInProgress = false

    func snapshotAndBeginRefresh() -> (snapshot: LiveHelperStatus, shouldRefresh: Bool) {
        lock.withLock {
            let shouldRefresh = !refreshInProgress
            refreshInProgress = true
            return (snapshot, shouldRefresh)
        }
    }

    func finishRefresh(_ snapshot: LiveHelperStatus) {
        lock.withLock {
            self.snapshot = snapshot
            refreshInProgress = false
        }
    }
}
```

- [ ] **Step 4: Use the cache from `HelperTool.getStatus`**

Add one utility queue and one cache. `getStatus` must read the monitor snapshot and cached live snapshot, encode/reply synchronously without launching a process, then enqueue this coalesced refresh when `shouldRefresh` is true:

```swift
private func refreshLiveStatus() {
    let broadRoutes = BroadRouteManager.countPresentRoutes()
    statusCache.finishRefresh(LiveHelperStatus(
        zscalerRunning: ZscalerServiceManager.isRunning(),
        zscalerInterface: RouteEngine.detectZscalerInterface(),
        broadIPv4: broadRoutes.ipv4,
        broadIPv6: broadRoutes.ipv6,
        networkSignature: NetworkDetector.getNetworkSignature()
    ))
}
```

Schedule an initial refresh from `init` so the second UI poll has live state. If encoding fails, keep the existing empty-data reply and log.

- [ ] **Step 5: Verify cache tests and both unit-test schemes**

Run:

```bash
cd macOS
xcodebuild test -project ZscalerSplitTunnel.xcodeproj -scheme ZscalerSplitTunnelHelperTests -destination 'platform=macOS'
xcodebuild test -project ZscalerSplitTunnel.xcodeproj -scheme ZscalerSplitTunnelTests -destination 'platform=macOS'
```

Expected: both schemes pass with zero failures.

- [ ] **Step 6: Commit**

```bash
git status --short
git add macOS/ZscalerSplitTunnelHelper/HelperStatusCache.swift \
  macOS/ZscalerSplitTunnelHelper/HelperTool.swift \
  macOS/ZscalerSplitTunnelHelperTests/HelperStatusCacheTests.swift \
  macOS/project.yml macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj
git commit -m "fix(helper): return cached status"
```

### Task 3: Split light and full reconciliation cadence

**Files:**
- Create: `macOS/ZscalerSplitTunnelHelper/ReconciliationSchedule.swift`
- Create: `macOS/ZscalerSplitTunnelHelperTests/ReconciliationScheduleTests.swift`
- Modify: `macOS/ZscalerSplitTunnelHelper/MonitorLoop.swift`
- Modify: `macOS/project.yml`
- Modify mechanically: `macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `ReconciliationSchedule.shouldRunFullRefresh(lastFullRefresh:now:forced:) -> Bool`.
- Full interval is `AppConstants.cacheExpireSeconds` (300 seconds).

- [ ] **Step 1: Write failing scheduling tests**

```swift
import XCTest

final class ReconciliationScheduleTests: XCTestCase {
    func testRunsInitiallyAndWhenForced() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(ReconciliationSchedule.shouldRunFullRefresh(lastFullRefresh: nil, now: now))
        XCTAssertTrue(ReconciliationSchedule.shouldRunFullRefresh(
            lastFullRefresh: now,
            now: now,
            forced: true
        ))
    }

    func testWaitsFiveMinutesBetweenFullRefreshes() {
        let last = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ReconciliationSchedule.shouldRunFullRefresh(
            lastFullRefresh: last,
            now: last.addingTimeInterval(299)
        ))
        XCTAssertTrue(ReconciliationSchedule.shouldRunFullRefresh(
            lastFullRefresh: last,
            now: last.addingTimeInterval(300)
        ))
    }
}
```

- [ ] **Step 2: Add the production file to both helper targets and verify RED**

Add the file to the helper-test source list, regenerate the project with `xcodegen generate`, and run only `ReconciliationScheduleTests`.

Expected: compile failure because `ReconciliationSchedule` does not exist.

- [ ] **Step 3: Implement the pure schedule**

```swift
import Foundation

enum ReconciliationSchedule {
    static func shouldRunFullRefresh(
        lastFullRefresh: Date?,
        now: Date,
        forced: Bool = false
    ) -> Bool {
        forced || lastFullRefresh.map {
            now.timeIntervalSince($0) >= TimeInterval(AppConstants.cacheExpireSeconds)
        } ?? true
    }
}
```

- [ ] **Step 4: Apply the schedule in `MonitorLoop`**

Add `lastFullRefresh: Date?`. Reset it in `start`. In an unchanged ordinary cycle, always run `sweepBroadRoutesAndRepairIPv6Default()`, but call `addCustomRoutes()` and `addBypassRoutes()` only when the schedule is due. Record the time after every full application. Network changes, config changes, gateway changes, initial startup, and manual refresh continue through `reloadAndApplyRoutes` and must update `lastFullRefresh` immediately.

Keep interface inventory, office evaluation, default-route checks, config mtime checks, signature checks, and snapshot updates on every 30-second cycle.

- [ ] **Step 5: Verify focused tests, both full schemes, and builds**

Run:

```bash
cd macOS
xcodebuild test -project ZscalerSplitTunnel.xcodeproj -scheme ZscalerSplitTunnelHelperTests -destination 'platform=macOS'
xcodebuild test -project ZscalerSplitTunnel.xcodeproj -scheme ZscalerSplitTunnelTests -destination 'platform=macOS'
xcodebuild build -project ZscalerSplitTunnel.xcodeproj -scheme ZscalerSplitTunnel -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project ZscalerSplitTunnel.xcodeproj -scheme com.zscaler-split-tunnel.helper -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: tests and builds exit 0 with zero failures.

- [ ] **Step 6: Commit**

```bash
git status --short
git add macOS/ZscalerSplitTunnelHelper/ReconciliationSchedule.swift \
  macOS/ZscalerSplitTunnelHelper/MonitorLoop.swift \
  macOS/ZscalerSplitTunnelHelperTests/ReconciliationScheduleTests.swift \
  macOS/project.yml macOS/ZscalerSplitTunnel.xcodeproj/project.pbxproj
git commit -m "fix(monitor): separate reconciliation cadence"
```

### Task 4: Verify the integrated behavior

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: bounded `ShellRunner`, cached `getStatus`, and five-minute full reconciliation.
- Produces: verification evidence only.

- [ ] **Step 1: Run clean, complete verification**

Run the two full test commands and two build commands from Task 3 again after all commits. Run `git diff --check HEAD~3..HEAD`.

- [ ] **Step 2: Verify status latency from a signed local app build**

Launch the signed app build, reinstall its helper through the existing UI, then sample five status polls while a monitor cycle is active. Each XPC reply must arrive below the app's five-second timeout and the UI must not show `Helper not responding`.

- [ ] **Step 3: Verify cadence in privileged logs**

Run:

```bash
sudo log stream --style compact \
  --predicate 'subsystem == "com.zscaler-split-tunnel.helper"'
```

Observe at least two 30-second cycles and one five-minute boundary. Broad-route removals may occur every 30 seconds; `ConfigLoader` full route loading must occur only at startup/forced refresh and the five-minute boundary.

- [ ] **Step 4: Confirm final repository state**

Run `git status --short --branch`, verify all new commits have good SSH signatures, and confirm `split-shield-icon.svg` remains untracked. Do not push.

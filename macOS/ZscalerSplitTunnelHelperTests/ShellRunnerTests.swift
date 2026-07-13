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

    func testTimeoutDoesNotWaitForDescendantPipeHolders() {
        let started = Date()
        let result = ShellRunner.runCapturingStderr(
            "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 5 & printf stdout; printf stderr >&2; wait"],
            timeout: 0.1
        )
        XCTAssertEqual(result.exitCode, ShellRunner.timeoutExitCode)
        XCTAssertEqual(result.stdout, "stdout")
        XCTAssertEqual(result.stderr, "stderr")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testRunReturnsNilForInvalidUTF8() {
        let result = ShellRunner.run("/usr/bin/printf", arguments: ["\\377"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertNil(result.output)
    }
}

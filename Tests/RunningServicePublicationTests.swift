import Combine
import XCTest
@testable import StackBar

@MainActor
final class RunningServicePublicationTests: XCTestCase {
    func testRepeatedUnchangedHealthCheckDoesNotPublish() {
        let runner = makeRunner()
        runner.refreshHealth(processIsRunning: true, portIsOpen: nil)

        var publicationCount = 0
        let observation = runner.objectWillChange.sink { publicationCount += 1 }

        runner.refreshHealth(processIsRunning: true, portIsOpen: nil)

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testUnchangedAndInsignificantMemorySamplesDoNotPublish() {
        let runner = makeRunner()
        runner.refreshHealth(processIsRunning: true, portIsOpen: nil)
        runner.setMemoryBytes(10 * 1_048_576)

        var publicationCount = 0
        let observation = runner.objectWillChange.sink { publicationCount += 1 }

        runner.setMemoryBytes(10 * 1_048_576)
        runner.setMemoryBytes(10 * 1_048_576 + 512 * 1024)

        XCTAssertEqual(publicationCount, 0)

        runner.setMemoryBytes(11 * 1_048_576)

        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(runner.memoryBytes, 11 * 1_048_576)
        withExtendedLifetime(observation) {}
    }

    private func makeRunner() -> RunningService {
        RunningService(config: Service(
            name: "Publication test",
            directory: NSTemporaryDirectory(),
            commands: [Command(run: "true")]
        ))
    }
}

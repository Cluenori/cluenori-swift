import CluenoriIngest
import Foundation
import Testing

@testable import CluenoriPerformance

private let processStart = Date(timeIntervalSince1970: 1_792_000_000)

struct LaunchTimingTests {
    @Test func `a cold launch is timed from its process's start to the first frame and to ready`() {
        let timing = LaunchTiming.measure(
            processStart: processStart, firstFrame: processStart.addingTimeInterval(0.4123),
            ready: processStart.addingTimeInterval(1.25), prewarmed: false, launchedInBackground: false)
        #expect(timing == LaunchTiming(start: .cold, prewarmed: false, firstFrameMs: 412, readyMs: 1250))
    }

    @Test func `a prewarmed launch is warm and says so, since its time isn't comparable`() {
        let timing = LaunchTiming.measure(
            processStart: processStart, firstFrame: processStart.addingTimeInterval(95), ready: nil, prewarmed: true,
            launchedInBackground: false)
        #expect(timing == LaunchTiming(start: .warm, prewarmed: true, firstFrameMs: 95_000, readyMs: nil))
    }

    @Test func `a process launched in the background and opened later is warm`() {
        let timing = LaunchTiming.measure(
            processStart: processStart, firstFrame: processStart.addingTimeInterval(600), ready: nil, prewarmed: false,
            launchedInBackground: true)
        #expect(timing?.start == .warm)
        #expect(timing?.prewarmed == false)
    }

    @Test func `a launch whose clock moved back isn't recorded, and a ready before the start is left out`() {
        #expect(
            LaunchTiming.measure(
                processStart: processStart, firstFrame: processStart.addingTimeInterval(-1), ready: nil,
                prewarmed: false,
                launchedInBackground: false) == nil)
        let timing = LaunchTiming.measure(
            processStart: processStart, firstFrame: processStart.addingTimeInterval(1),
            ready: processStart.addingTimeInterval(-2), prewarmed: false, launchedInBackground: false)
        #expect(timing?.readyMs == nil)
    }

    @Test func `this process's start comes from the kernel, before now`() throws {
        let start = try #require(LaunchTiming.processStart())
        #expect(start < Date())
        #expect(Date().timeIntervalSince(start) < 24 * 3600)
    }

    @Test func `the memory footprint is read, and its peak is at least it`() throws {
        let memory = try #require(MemoryFootprint.now())
        #expect(memory.footprintBytes > 0)
        #expect(memory.peakBytes >= memory.footprintBytes)
    }
}

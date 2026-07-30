import AllwardCore
import Foundation

struct CommandRegionReducer: Sendable {
    private let clock: any AllwardClock
    private(set) var regions: [CommandRegion] = []
    private var currentIndex: Int?
    private var commandBuffer = ""
    private var workingDirectory: String?

    init(clock: any AllwardClock) {
        self.clock = clock
    }

    mutating func setWorkingDirectory(_ value: String) {
        if let url = URL(string: value), url.scheme == "file" {
            workingDirectory = url.path.removingPercentEncoding ?? url.path
        } else {
            workingDirectory = value
        }
    }

    mutating func appendCommandInput(_ text: String) {
        guard let currentIndex, regions[currentIndex].phase == .inputStart else { return }
        commandBuffer += text
    }

    mutating func control(_ control: C0Control) {
        guard let currentIndex, regions[currentIndex].phase == .inputStart else { return }
        switch control {
        case .backspace:
            if !commandBuffer.isEmpty { commandBuffer.removeLast() }
        case .carriageReturn, .lineFeed: commandBuffer.append("\n")
        default: break
        }
    }

    mutating func apply(_ marker: OSCCommandMarker, line: LineID) {
        switch marker.phase {
        case .promptStart:
            regions.append(CommandRegion(
                promptLine: line,
                phase: .promptStart,
                workingDirectory: workingDirectory,
                startedAt: clock.now
            ))
            currentIndex = regions.count - 1
            commandBuffer = ""
        case .inputStart:
            ensureCurrent(line: line)
            guard let currentIndex else { return }
            regions[currentIndex].inputLine = line
            regions[currentIndex].phase = .inputStart
            commandBuffer = ""
        case .outputStart:
            ensureCurrent(line: line)
            guard let currentIndex else { return }
            regions[currentIndex].outputLine = line
            regions[currentIndex].phase = .outputStart
            let command = commandBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            regions[currentIndex].commandText = command.isEmpty ? nil : command
        case .finished:
            ensureCurrent(line: line)
            guard let currentIndex else { return }
            regions[currentIndex].endLine = line
            regions[currentIndex].phase = .finished
            regions[currentIndex].endedAt = clock.now
            if let value = marker.parameters["exit"], let code = Int32(value) {
                regions[currentIndex].exitCode = code
            }
            self.currentIndex = nil
            commandBuffer = ""
        }
    }

    mutating func reset() {
        regions.removeAll(keepingCapacity: true)
        currentIndex = nil
        commandBuffer = ""
        workingDirectory = nil
    }

    private mutating func ensureCurrent(line: LineID) {
        if currentIndex == nil {
            regions.append(CommandRegion(
                promptLine: line,
                workingDirectory: workingDirectory,
                startedAt: clock.now
            ))
            currentIndex = regions.count - 1
        }
    }
}

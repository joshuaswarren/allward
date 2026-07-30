import AllwardCore
import AllwardTerminal
import Foundation

extension ControlService {
    public func runCommand(
        target: Target,
        generation: Generation,
        command: String,
        bound: AttemptBound = .controlRequest,
        idempotencyKey: IdempotencyKey
    ) async -> RunCommandResult {
        do {
            return try await ledger.perform(key: idempotencyKey) {
                await self.performRunCommand(
                    target: target,
                    generation: generation,
                    command: command,
                    idempotencyKey: idempotencyKey,
                    bound: bound
                )
            }
        } catch {
            return .rejected(controlFailure(operation: "run-command-idempotency", error: error))
        }
    }

    public func recoverCommand(
        _ key: IdempotencyKey
    ) async -> RunCommandResult? {
        try? await ledger.lookup(key, as: RunCommandResult.self)
    }
    public func recoverCommandReceipt(
        _ key: IdempotencyKey
    ) -> CommandExecutionReceipt? {
        commandReceipts[key]
    }


    private func performRunCommand(
        target: Target,
        generation: Generation,
        command: String,
        idempotencyKey: IdempotencyKey,
        bound: AttemptBound
    ) async -> RunCommandResult {
        guard let paneID = target.pane else {
            return .rejected(.targetMismatch(expected: target, actual: target))
        }
        if let rejection = await registry.rejection(for: target, expectedGeneration: generation) {
            return .rejected(rejection)
        }
        guard let session = await registry.session(for: paneID) else {
            return .rejected(.paneNotFound(paneID))
        }
        let commandID = UUID()
        recordCommandReceipt(
            CommandExecutionReceipt(
                commandID: commandID,
                idempotencyKey: idempotencyKey,
                target: target,
                generation: generation,
                status: .accepted
            )
        )
        let regions = await session.commandRegions()
        let existing = Set(regions.map(\.id))
        let input = await deliverInput(
            kind: .runCommand,
            target: target,
            generation: generation,
            source: .mcp
        ) { session in
            guard await session.paste(command) else { return false }
            return await session.write([0x0D])
        }
        if case .applied = input {
            updateCommandReceipt(idempotencyKey, status: .committed)
        }
        guard case let .applied(receipt) = input else {
            updateCommandReceipt(idempotencyKey, status: .cancelled)
            if case let .rejected(rejection) = input { return .rejected(rejection) }
            return .rejected(.unsupported("Command input was not accepted"))
        }
        guard let region = await session.nextFinishedCommand(
            after: existing,
            timeout: .seconds(bound.totalTimeout)
        ) else {
            updateCommandReceipt(idempotencyKey, status: .outcomeUnknown)
            return .rejected(
                .failed(
                    AllwardError(
                        domain: .control,
                        operation: "run-command",
                        cause: "No OSC 133 command completion arrived before the deadline",
                        retryability: .retryable,
                        recovery: "Retry after confirming shell integration is active."
                    )
                )
            )
        }
        guard let exitCode = region.exitCode else {
            updateCommandReceipt(idempotencyKey, status: .error)
            return .rejected(.unsupported("The completion marker did not include an exit code"))
        }
        let snapshot = await session.snapshot()
        let historyLimit = min(10_024, snapshot.scrollbackCount + snapshot.geometry.rows)
        let entries = await session.historyEntries(lines: historyLimit)
        let output = entries.compactMap { entry -> String? in
            guard let outputLine = region.outputLine else { return nil }
            guard entry.line >= outputLine else { return nil }
            if let endLine = region.endLine, entry.line > endLine { return nil }
            return entry.text
        }
        updateCommandReceipt(idempotencyKey, status: .final, exitCode: exitCode)
        return .completed(
            CommandOutcome(
                pane: paneID,
                command: command,
                exitCode: exitCode,
                output: output,
                region: region
            ),
            receipt
        )
    }
    private func recordCommandReceipt(_ receipt: CommandExecutionReceipt) {
        if commandReceipts[receipt.idempotencyKey] == nil {
            commandReceiptOrder.append(receipt.idempotencyKey)
        }
        commandReceipts[receipt.idempotencyKey] = receipt
        while commandReceiptOrder.count > 2_048 {
            let expired = commandReceiptOrder.removeFirst()
            commandReceipts[expired] = nil
        }
    }

    private func updateCommandReceipt(
        _ key: IdempotencyKey,
        status: CommandReceiptStatus,
        exitCode: Int32? = nil
    ) {
        guard var receipt = commandReceipts[key] else { return }
        receipt.status = status
        receipt.exitCode = exitCode
        commandReceipts[key] = receipt
    }

}

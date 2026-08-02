import AllwardCore
import Foundation

/// Classifies an SSH failure message into the retryability the presentation layer
/// needs.
///
/// It reads text because the failures it classifies arrive as text: OpenSSH's
/// stderr from the Developer ID forwarding path. The russh transport reports typed
/// failures instead and does not need this, which is why it moved here with
/// `SSHPortForwarding` rather than staying in the transport.
public enum SSHFailureKind: Hashable, Sendable {
    case trustDenied
    case nonretryable
    case retryable
}

public enum SSHFailureClassifier {
    public static func classify(_ text: String) -> SSHFailureKind? {
        let message = text.lowercased()
        if message.contains("remote host identification has changed")
            || message.contains("host key verification failed")
            || message.contains("host key mismatch")
            || message.contains("permission denied")
        {
            return .trustDenied
        }
        if message.contains("could not resolve hostname") {
            return .nonretryable
        }
        if message.contains("connection refused")
            || message.contains("connection timed out")
            || message.contains("operation timed out")
        {
            return .retryable
        }
        return nil
    }

    static func classifyFinalDiagnostic(_ text: String) -> SSHFailureKind? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for line in lines {
            if line.contains("remote host identification has changed")
                || line.contains("host key verification failed")
                || line.contains("host key mismatch")
            {
                return .trustDenied
            }
            if line.hasPrefix("permission denied")
                || (line.contains("@") && line.contains(": permission denied"))
            {
                return .trustDenied
            }
            guard line.hasPrefix("ssh:") else { continue }
            if line.contains("could not resolve hostname") { return .nonretryable }
            if line.contains("connection refused")
                || line.contains("connection timed out")
                || line.contains("operation timed out")
            {
                return .retryable
            }
        }
        return nil
    }
}

import Foundation

/// Everything that can go wrong talking to the controller.
enum ControllerError: Error, LocalizedError, Equatable, Sendable {
    /// The controller answered with a 4xx/5xx and `{"error": message}`.
    case server(status: Int, message: String)
    /// No answer within the request timeout.
    case timeout
    /// Couldn't reach the controller at all.
    case unreachable(String)
    /// The address the user typed isn't a usable host.
    case invalidAddress(String)
    /// The controller answered with something that isn't the expected JSON.
    case invalidResponse(String)

    /// The server's own `error` message, when there is one.
    var serverMessage: String? {
        if case .server(_, let message) = self { return message }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .server(let status, let message):
            return "\(message) (\(status))"
        case .timeout:
            return "The controller didn't answer in time."
        case .unreachable(let detail):
            return "Can't reach the controller. \(detail)"
        case .invalidAddress(let text):
            return "“\(text)” isn't a valid controller address."
        case .invalidResponse(let detail):
            return "Unexpected response from the controller. \(detail)"
        }
    }

    /// Wraps any error thrown while making a request.
    static func from(_ error: Error) -> ControllerError {
        if let e = error as? ControllerError { return e }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut: return .timeout
            default: return .unreachable(e.localizedDescription)
            }
        }
        if error is DecodingError { return .invalidResponse(String(describing: error)) }
        return .unreachable(error.localizedDescription)
    }
}

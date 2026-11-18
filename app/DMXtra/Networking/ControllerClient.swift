import Foundation

/// The only way the app talks to the controller.
///
/// The controller handles one connection at a time and closes it after every
/// response, so every request goes through a single serial chain: a request
/// doesn't start until the one before it has finished.
actor ControllerClient {
    nonisolated let baseURL: URL
    private let session: URLSession
    private var tail: Task<Void, Never>?

    init(baseURL: URL, timeout: TimeInterval = 3) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    // MARK: - Endpoints (see embedded/API.md)

    func info() async throws -> ControllerInfo {
        try await decode(send("GET", "/"))
    }

    func fixtureTypes() async throws -> [FixtureType] {
        try await decode(send("GET", "/fixture-types"))
    }

    func fixtures() async throws -> [Fixture] {
        try await decode(send("GET", "/fixtures"))
    }

    func fixture(id: Int) async throws -> Fixture {
        try await decode(send("GET", "/fixtures/\(id)"))
    }

    func createFixture(_ new: NewFixture) async throws -> Fixture {
        try await decode(send("POST", "/fixtures", body: new))
    }

    func updateFixture(id: Int, _ update: FixtureUpdate) async throws -> Fixture {
        try await decode(send("PATCH", "/fixtures/\(id)", body: update))
    }

    func deleteFixture(id: Int) async throws {
        _ = try await send("DELETE", "/fixtures/\(id)")
    }

    func dmx(start: Int? = nil, count: Int? = nil) async throws -> DmxRange {
        var query: [URLQueryItem] = []
        if let start { query.append(URLQueryItem(name: "start", value: String(start))) }
        if let count { query.append(URLQueryItem(name: "count", value: String(count))) }
        return try await decode(send("GET", "/dmx", query: query))
    }

    @discardableResult
    func setDmx(_ range: DmxRange) async throws -> DmxWriteResult {
        try await decode(send("POST", "/dmx", body: range))
    }

    func blackout() async throws {
        _ = try await send("POST", "/blackout")
    }

    // MARK: - Plumbing

    private func send(_ method: String, _ path: String, body: some Encodable) async throws -> Data {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw ControllerError.invalidResponse("Couldn't encode the request: \(error)")
        }
        return try await send(method, path, bodyData: data)
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        bodyData: Data? = nil
    ) async throws -> Data {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw ControllerError.invalidAddress(baseURL.absoluteString) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let isIdempotent = method == "GET"
        let req = request
        return try await serialized { [session] in
            try await Self.perform(req, session: session, retryOnDrop: isIdempotent)
        }
    }

    /// Runs `work` after every previously queued request has finished.
    private func serialized<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await work()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    private static func perform(_ request: URLRequest, session: URLSession, retryOnDrop: Bool) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where retryOnDrop && error.code == .networkConnectionLost {
            // The board drops the socket after each response; a GET is safe to retry once.
            return try await perform(request, session: session, retryOnDrop: false)
        } catch {
            throw ControllerError.from(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ControllerError.invalidResponse("Not an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ServerErrorBody.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ControllerError.server(status: http.statusCode, message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ControllerError.invalidResponse(String(describing: error))
        }
    }
}

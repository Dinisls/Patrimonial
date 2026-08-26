import Foundation

protocol NetworkClient: Sendable {
    func fetch<T: Decodable>(_ request: URLRequest) async throws -> T
}

struct URLSessionNetworkClient: NetworkClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum NetworkError: LocalizedError {
    case invalidResponse
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: String(localized: "error_invalid_response")
        case .decodingFailed: String(localized: "error_decoding_failed")
        }
    }
}

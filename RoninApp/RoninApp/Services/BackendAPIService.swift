import Foundation

class BackendAPIService {
    private let baseURL: String
    var authToken: String = ""

    init(baseURL: String = "http://127.0.0.1:8000") {
        self.baseURL = baseURL
    }

    func setupMeeting(config: MeetingConfig) async throws -> MeetingSetupResponse {
        guard let url = URL(string: "\(baseURL)/meeting/setup") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(config)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw parseError(data: data, fallback: "Failed to set up meeting")
        }

        return try JSONDecoder().decode(MeetingSetupResponse.self, from: data)
    }

    func endMeeting(sessionId: String) async throws -> MeetingSummaryResponse {
        guard let url = URL(string: "\(baseURL)/meeting/end?session_id=\(sessionId)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60 // Summary generation can take a while

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw parseError(data: data, fallback: "Failed to generate summary")
        }

        return try JSONDecoder().decode(MeetingSummaryResponse.self, from: data)
    }

    func checkHealth() async -> Bool {
        guard let url = URL(string: "\(baseURL)/meeting/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Detailed Health Check

    struct HealthDetails: Decodable {
        let status: String
        let dependencies: [String: DependencyInfo]

        struct DependencyInfo: Decodable {
            let status: String
            let provider: String?
            let detail: String?
            let model: String?
            let context_length: Int?
            let active: Bool?
            let segments: Int?
        }
    }

    func checkHealthDetailed() async -> HealthDetails? {
        guard let url = URL(string: "\(baseURL)/meeting/health?details=true") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(HealthDetails.self, from: data)
        } catch {
            return nil
        }
    }

    // MARK: - Graceful Shutdown

    func requestGracefulShutdown() async -> Bool {
        guard let url = URL(string: "\(baseURL)/meeting/shutdown") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // Parse FastAPI error responses: {"detail": "..."}
    private func parseError(data: Data, fallback: String) -> APIError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = json["detail"] as? String {
            return .serverError(detail)
        }
        return .serverError(fallback)
    }

    enum APIError: LocalizedError {
        case invalidURL
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL"
            case .serverError(let detail): return detail
            }
        }
    }
}

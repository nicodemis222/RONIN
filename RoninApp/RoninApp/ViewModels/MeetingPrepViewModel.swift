import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class MeetingPrepViewModel: ObservableObject {
    @Published var title: String = ""
    @Published var goal: String = ""
    @Published var constraints: String = ""
    @Published var noteFiles: [NotePayload] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let backendAPI = BackendAPIService()

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !goal.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func canStart(backendStatus: BackendProcessService.Status) -> Bool {
        isValid && !isLoading && backendStatus.isRunning
    }

    func addNoteFiles(urls: [URL]) {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            if let content = readFileContent(url: url) {
                if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorMessage = "\(url.lastPathComponent) is empty."
                    continue
                }
                noteFiles.append(NotePayload(
                    name: url.lastPathComponent,
                    content: content
                ))
            } else {
                errorMessage = "Could not read \(url.lastPathComponent). Ensure it's a text file."
            }
        }
    }

    private func readFileContent(url: URL) -> String? {
        let encodings: [String.Encoding] = [.utf8, .macOSRoman, .ascii, .isoLatin1]
        for encoding in encodings {
            if let content = try? String(contentsOf: url, encoding: encoding) {
                return content
            }
        }
        return nil
    }

    func removeNote(at offsets: IndexSet) {
        noteFiles.remove(atOffsets: offsets)
    }

    func startMeeting() async -> MeetingSetupResponse? {
        isLoading = true
        errorMessage = nil

        // Pre-flight health check
        let healthy = await backendAPI.checkHealth()
        if !healthy {
            errorMessage = "Backend is not responding. It may still be starting up — wait a moment and try again."
            isLoading = false
            return nil
        }

        let config = MeetingConfig(
            title: title,
            goal: goal,
            constraints: constraints,
            notes: noteFiles
        )

        do {
            let response = try await backendAPI.setupMeeting(config: config)
            guard !response.session_id.isEmpty else {
                errorMessage = "Backend returned an invalid session."
                isLoading = false
                return nil
            }
            isLoading = false
            return response
        } catch {
            errorMessage = "Failed to start meeting: \(error.localizedDescription)"
            isLoading = false
            return nil
        }
    }
}

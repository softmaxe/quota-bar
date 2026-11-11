import Foundation

actor CodexCredentialCache {
    private var source: URL?
    private var diskCredentials: CodexCredentials?
    private var session: CodexCredentialSession?

    func load(env: [String: String], credentialLoader: CodexCredentialLoader?) throws -> CodexCredentialSession {
        let credentials: CodexCredentials
        do {
            credentials = try credentialLoader?() ?? CodexCredentialsStore.load(env: env)
        } catch {
            // A missing or unreadable file must not let cached credentials conceal sign-out.
            self.diskCredentials = nil
            self.session = nil
            throw error
        }

        let source = CodexCredentialsStore.authFileURL(env: env)
        if self.source == source, self.diskCredentials == credentials, let session {
            return session
        }

        // Keep the disk identity separate from rotated tokens. Replacing the session also
        // prevents an older in-flight refresh from restoring credentials after a new login.
        let session = CodexCredentialSession(credentials: credentials)
        self.source = source
        self.diskCredentials = credentials
        self.session = session
        return session
    }
}

actor CodexCredentialSession {
    private(set) var credentials: CodexCredentials
    private var refreshTask: Task<CodexCredentials, Error>?

    init(credentials: CodexCredentials) {
        self.credentials = credentials
    }

    func refresh(
        _ previous: CodexCredentials,
        transport: any HTTPTransport
    ) async throws -> CodexCredentials {
        // Another poll may have already replaced the token rejected by this usage request.
        if self.credentials != previous { return self.credentials }
        if let refreshTask { return try await refreshTask.value }

        // Actors can reenter during network I/O; share the task so a rotating refresh token
        // is exchanged only once, and retain its result without writing the CLI's auth.json.
        let task = Task {
            defer { self.refreshTask = nil }
            let refreshed = try await CodexTokenRefresher.refresh(previous, transport: transport)
            self.credentials = refreshed
            return refreshed
        }
        self.refreshTask = task
        return try await task.value
    }
}

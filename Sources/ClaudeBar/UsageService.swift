import AppKit
import Foundation
import Security
import UserNotifications

/// Fetches Claude usage limits from Anthropic API.
///
/// Handles OAuth token refresh automatically when tokens expire.
/// Updates are fetched on init and at the configured interval thereafter.
@MainActor
@Observable
final class UsageService {

    // MARK: - Public State

    private(set) var usage: UsageResponse?
    private(set) var error: String?
    private(set) var lastUpdate: Date?
    private(set) var isLoading = false
    private(set) var planType: String?
    private(set) var languageRefreshID = 0

    // MARK: - Previous Usage (for threshold detection)

    private var previousFiveHour: Int?
    private var previousSevenDay: Int?
    private var previousSevenDaySonnet: Int?
    private var previousExtraUsage: Int?

    // MARK: - Settings (persisted)

    var showPercentage: Bool {
        didSet { UserDefaults.standard.set(showPercentage, forKey: "showPercentage") }
    }

    var refreshInterval: Int {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            restartPolling()
        }
    }

    var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage")
            invalidateBundleCache()
            languageRefreshID += 1
        }
    }

    // MARK: - Notification Settings (persisted)

    var notifyAt50: Bool {
        didSet { UserDefaults.standard.set(notifyAt50, forKey: "notifyAt50") }
    }

    var notifyAt75: Bool {
        didSet { UserDefaults.standard.set(notifyAt75, forKey: "notifyAt75") }
    }

    var notifyAt100: Bool {
        didSet { UserDefaults.standard.set(notifyAt100, forKey: "notifyAt100") }
    }

    var notifyOnReset: Bool {
        didSet { UserDefaults.standard.set(notifyOnReset, forKey: "notifyOnReset") }
    }

    // MARK: - Configuration

    private let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private let tokenURL = "https://platform.claude.com/v1/oauth/token"
    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let keychainService = "Claude Code-credentials"

    private var pollingTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init() {
        let defaults = UserDefaults.standard
        showPercentage = defaults.object(forKey: "showPercentage") as? Bool ?? true
        refreshInterval = defaults.object(forKey: "refreshInterval") as? Int ?? 60
        notifyAt50 = defaults.object(forKey: "notifyAt50") as? Bool ?? true
        notifyAt75 = defaults.object(forKey: "notifyAt75") as? Bool ?? true
        notifyAt100 = defaults.object(forKey: "notifyAt100") as? Bool ?? true
        notifyOnReset = defaults.object(forKey: "notifyOnReset") as? Bool ?? false
        let langRaw = defaults.string(forKey: "appLanguage") ?? "system"
        appLanguage = AppLanguage(rawValue: langRaw) ?? .system

        requestNotificationPermission()
        Task { await refresh() }
        startPolling()
    }

    /// Cancel the polling task. Call this instead of relying on deinit.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Public Methods

    /// Force-refresh: clears any rate limit backoff and fetches immediately
    func forceRefresh() async {
        rateLimitedUntil = nil
        consecutiveRateLimits = 0
        await refresh()
    }

    /// Fetches latest usage data from API
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard let credentials = readKeychain() else {
            error = L("error.not_logged_in")
            return
        }

        guard let token = credentials.claudeAiOauth?.accessToken else {
            error = L("error.no_access_token")
            return
        }

        planType = credentials.claudeAiOauth?.subscriptionType

        // Try request with current token
        switch await fetchUsage(token: token) {
        case .success(let data):
            parseUsage(data)

        case .unauthorized:
            // Token expired, try refresh
            await handleTokenRefresh(credentials: credentials)

        case .rateLimited(let retryAfter):
            let mins = Int(ceil(retryAfter / 60))
            if mins > 1 {
                error = "Rate limited — retrying in \(mins)m"
            } else {
                error = "Rate limited — retrying shortly"
            }

        case .error(let message):
            error = message
        }
    }

    // MARK: - API Requests

    private enum APIResult {
        case success(Data)
        case unauthorized
        case rateLimited(retryAfter: TimeInterval)
        case error(String)
    }

    // MARK: - Rate limit state
    private var rateLimitedUntil: Date? = nil
    private var consecutiveRateLimits: Int = 0

    private func fetchUsage(token: String) async -> APIResult {
        guard let url = URL(string: usageURL) else {
            return .error(L("error.invalid_url"))
        }

        // Respect rate limit backoff
        if let until = rateLimitedUntil, until > Date() {
            let wait = until.timeIntervalSinceNow
            return .rateLimited(retryAfter: wait)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 0

            switch status {
            case 200:
                rateLimitedUntil = nil
                consecutiveRateLimits = 0
                return .success(data)
            case 401:
                return .unauthorized
            case 429:
                // Respect Retry-After header, or use exponential backoff
                consecutiveRateLimits += 1
                let serverRetry = httpResponse?.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Double($0) }
                let backoff = serverRetry ?? min(60.0 * Double(consecutiveRateLimits), 600.0)
                rateLimitedUntil = Date().addingTimeInterval(backoff)
                return .rateLimited(retryAfter: backoff)
            default:
                return .error(L("error.http", status))
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func parseUsage(_ data: Data) {
        do {
            let newUsage = try JSONDecoder().decode(UsageResponse.self, from: data)
            checkAllThresholds(newUsage)
            usage = newUsage
            error = nil
            lastUpdate = Date()
        } catch {
            self.error = L("error.parse")
        }
    }

    // MARK: - Token Refresh

    private func handleTokenRefresh(credentials: KeychainCredentials) async {
        guard let refreshToken = credentials.claudeAiOauth?.refreshToken else {
            error = L("error.no_refresh_token")
            return
        }

        guard let newToken = await refreshAccessToken(refreshToken, credentials: credentials) else {
            error = L("error.token_refresh_failed")
            return
        }

        // Retry with new token
        if case .success(let data) = await fetchUsage(token: newToken) {
            parseUsage(data)
        } else {
            error = L("error.request_failed")
        }
    }

    private func refreshAccessToken(_ refreshToken: String, credentials: KeychainCredentials) async -> String? {
        guard let url = URL(string: tokenURL) else { return nil }

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": "user:inference user:profile user:sessions:claude_code"
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)

            // Save new tokens to keychain
            saveTokens(
                accessToken: tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken ?? refreshToken,
                expiresIn: tokenResponse.expiresIn ?? 3600,
                original: credentials
            )

            return tokenResponse.accessToken
        } catch {
            return nil
        }
    }

    // MARK: - Keychain (Security framework)

    private func readKeychain() -> KeychainCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KeychainCredentials.self, from: data)
    }

    private func saveTokens(accessToken: String, refreshToken: String, expiresIn: Int, original: KeychainCredentials) {
        guard let oauth = original.claudeAiOauth else { return }

        let expiresAt = Date().timeIntervalSince1970 * 1000 + Double(expiresIn) * 1000

        let updated = KeychainCredentials(
            claudeAiOauth: KeychainCredentials.OAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                scopes: oauth.scopes,
                subscriptionType: oauth.subscriptionType,
                rateLimitTier: oauth.rateLimitTier
            )
        )

        guard let jsonData = try? JSONEncoder().encode(updated) else { return }

        // Delete old entry
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new entry
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: jsonData
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    // MARK: - Polling (async Task)

    private func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.refreshInterval ?? 60))
                guard !Task.isCancelled else { break }
                await self?.refresh()
                // Keep notification badge in sync (auto-clears if user enables in System Settings)
                await self?.refreshNotificationStatus()
            }
        }
    }

    private func restartPolling() {
        pollingTask?.cancel()
        startPolling()
    }

    // MARK: - Notifications (UNUserNotificationCenter)

    private(set) var notificationsAuthorized: Bool = false

    /// Checks current notification auth status and updates `notificationsAuthorized`.
    /// Always call this after any permission interaction.
    func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAuthorized = settings.authorizationStatus == .authorized
    }

    /// Called on launch — requests permission if not yet determined, then refreshes status.
    private func requestNotificationPermission() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
            await refreshNotificationStatus()
        }
    }

    /// Called by the Enable/Test button in Settings.
    func handleNotificationButtonTap() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            // Already good — fire test notifications
            fireTestNotifications()
        case .denied:
            // Can't prompt again — send user to System Settings
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
            // Poll for up to 30s in case they flip it on and come back
            Task {
                for _ in 0..<30 {
                    try? await Task.sleep(for: .seconds(1))
                    await refreshNotificationStatus()
                    if notificationsAuthorized { break }
                }
            }
        default:
            // Not determined — show system prompt
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            await refreshNotificationStatus()
            if granted { fireTestNotifications() }
        }
    }

    func sendTestNotification() {
        Task { await handleNotificationButtonTap() }
    }

    private func fireTestNotifications() {
        let resetTime = formatResetTime(hours: 2, minutes: 34)
        sendNotification(title: L("notification.50_title"), body: L("notification.test_50_body"))
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            sendNotification(title: L("notification.75_title"), body: L("notification.test_75_body"))
            try? await Task.sleep(for: .seconds(1.5))
            sendNotification(title: L("notification.limit_title"), body: L("notification.test_limit_body", resetTime))
            try? await Task.sleep(for: .seconds(1.5))
            sendNotification(title: L("notification.reset_title"), body: L("notification.test_reset_body"))
        }
    }

    private func formatResetTime(hours: Int, minutes: Int) -> String {
        if hours > 0 {
            return L("time.hours_minutes", hours, minutes)
        }
        return L("time.minutes", minutes)
    }

    private func getResetTimeFromBucket(_ bucket: UsageBucket?) -> String? {
        guard let bucket = bucket, let resetDate = bucket.resetDate else { return nil }
        let seconds = resetDate.timeIntervalSince(Date())
        guard seconds > 0 else { return nil }

        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return formatResetTime(hours: hours, minutes: minutes)
    }

    private func checkThresholds(oldValue: Int?, newValue: Int, limitName: String, resetTime: String?) {
        guard let old = oldValue else { return }

        if notifyAt50 && old < 50 && newValue >= 50 {
            sendNotification(
                title: L("notification.50_title"),
                body: L("notification.50_body", limitName)
            )
        }

        if notifyAt75 && old < 75 && newValue >= 75 {
            sendNotification(
                title: L("notification.75_title"),
                body: L("notification.75_body", limitName)
            )
        }

        if notifyAt100 && old < 100 && newValue >= 100 {
            let body: String
            if let time = resetTime {
                body = L("notification.limit_body_resets", limitName, time)
            } else {
                body = L("notification.limit_body", limitName)
            }
            sendNotification(title: L("notification.limit_title"), body: body)
        }

        if notifyOnReset && old > 0 && newValue == 0 {
            sendNotification(
                title: L("notification.reset_title"),
                body: L("notification.reset_body", limitName)
            )
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func checkAllThresholds(_ newUsage: UsageResponse) {
        if let bucket = newUsage.fiveHour {
            let resetTime = getResetTimeFromBucket(bucket)
            checkThresholds(oldValue: previousFiveHour, newValue: bucket.percent, limitName: L("limit.current_session"), resetTime: resetTime)
            previousFiveHour = bucket.percent
        }

        if let bucket = newUsage.sevenDay {
            let resetTime = getResetTimeFromBucket(bucket)
            checkThresholds(oldValue: previousSevenDay, newValue: bucket.percent, limitName: L("limit.weekly"), resetTime: resetTime)
            previousSevenDay = bucket.percent
        }

        if let bucket = newUsage.sevenDaySonnet {
            let resetTime = getResetTimeFromBucket(bucket)
            checkThresholds(oldValue: previousSevenDaySonnet, newValue: bucket.percent, limitName: L("limit.sonnet_weekly"), resetTime: resetTime)
            previousSevenDaySonnet = bucket.percent
        }

        if let extra = newUsage.extraUsage, extra.isEnabled {
            checkThresholds(oldValue: previousExtraUsage, newValue: extra.percent, limitName: L("limit.extra_usage"), resetTime: nil)
            previousExtraUsage = extra.percent
        }
    }
}

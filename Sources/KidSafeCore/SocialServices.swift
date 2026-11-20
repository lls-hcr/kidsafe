import Foundation

/// Réseau social ou messagerie bloquable individuellement (liste de domaines intégrée, pas de téléchargement).
public struct SocialService: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    /// Symbole SF affiché dans l'app.
    public var symbol: String
    public var domains: [String]

    /// Domaines vérifiés le 20/11/2026. Meta partage une partie de son infrastructure :
    /// `fbcdn.net` figure dans Facebook, ce qui peut aussi gêner l'affichage d'Instagram.
    public static let all: [SocialService] = [
        .init(id: "facebook", name: "Facebook", symbol: "f.circle",
              domains: ["facebook.com", "fb.com", "fb.me", "fbcdn.net", "facebook.net", "fbsbx.com", "messenger.com", "m.me"]),
        .init(id: "instagram", name: "Instagram", symbol: "camera",
              domains: ["instagram.com", "cdninstagram.com", "ig.me", "instagr.am"]),
        .init(id: "tiktok", name: "TikTok", symbol: "music.note",
              domains: ["tiktok.com", "tiktokv.com", "tiktokv.us", "tiktokv.eu", "tiktokcdn.com", "tiktokcdn-us.com", "tiktokcdn-eu.com",
                        "ttwstatic.com", "byteoversea.com", "ibytedtos.com", "ibyteimg.com", "musical.ly", "tiktokw.us", "tiktokw.eu"]),
        .init(id: "x", name: "X (Twitter)", symbol: "xmark",
              domains: ["x.com", "twitter.com", "twimg.com", "t.co", "twttr.com", "pscp.tv", "periscope.tv"]),
        .init(id: "snapchat", name: "Snapchat", symbol: "bubble.left",
              domains: ["snapchat.com", "snap.com", "snapkit.com", "sc-cdn.net", "sc-static.net", "snapads.com", "bitmoji.com"]),
        .init(id: "youtube", name: "YouTube", symbol: "play.rectangle",
              domains: ["youtube.com", "youtu.be", "ytimg.com", "googlevideo.com", "youtube-nocookie.com", "youtubei.googleapis.com", "yt.be"]),
        .init(id: "threads", name: "Threads", symbol: "at",
              domains: ["threads.net", "threads.com"]),
        .init(id: "whatsapp", name: "WhatsApp", symbol: "phone.bubble",
              domains: ["whatsapp.com", "whatsapp.net", "wa.me"]),
        .init(id: "telegram", name: "Telegram", symbol: "paperplane",
              domains: ["telegram.org", "telegram.me", "t.me", "telesco.pe", "tdesktop.com", "telegra.ph"]),
        .init(id: "discord", name: "Discord", symbol: "headphones",
              domains: ["discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media", "discord.new"]),
        .init(id: "reddit", name: "Reddit", symbol: "text.bubble",
              domains: ["reddit.com", "redd.it", "redditmedia.com", "redditstatic.com"]),
        .init(id: "twitch", name: "Twitch", symbol: "tv",
              domains: ["twitch.tv", "ttvnw.net", "jtvnw.net", "twitchcdn.net", "twitchsvc.net"]),
        .init(id: "pinterest", name: "Pinterest", symbol: "pin",
              domains: ["pinterest.com", "pinimg.com", "pin.it", "pinterest.fr", "pinterest.ch", "pinterest.de", "pinterest.co.uk", "pinterest.ca"]),
        .init(id: "bereal", name: "BeReal", symbol: "camera.on.rectangle",
              domains: ["bereal.com", "bere.al"]),
    ]

    public static func byID(_ id: String) -> SocialService? { all.first { $0.id == id } }
}

/// Plage horaire hebdomadaire. Jours ISO : 1 = lundi … 7 = dimanche.
/// `end <= start` : la plage passe minuit (ex. 21:00 → 07:00). `start == end` : toute la journée.
public struct TimeWindow: Codable, Sendable, Equatable, Hashable {
    public var days: [Int]
    /// Minutes depuis minuit.
    public var start: Int
    public var end: Int

    public init(days: [Int], start: Int, end: Int) {
        self.days = days; self.start = start; self.end = end
    }

    public static let weekdays = [1, 2, 3, 4, 5]
    public static let allDays = [1, 2, 3, 4, 5, 6, 7]

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = c.weekday else { return false }
        let day = (wd + 5) % 7 + 1            // Calendar : 1 = dimanche → ISO : 7
        let prev = day == 1 ? 7 : day - 1
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if start == end { return days.contains(day) }
        if start < end { return days.contains(day) && m >= start && m < end }
        return (days.contains(day) && m >= start) || (days.contains(prev) && m < end)
    }
}

/// Règle d'un réseau social.
public struct ServicePolicy: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Autorisé.
        case allowed
        /// Toujours bloqué.
        case blocked
        /// Bloqué pendant les plages (ex. nuits, heures d'école).
        case blockedDuring
        /// Autorisé seulement pendant les plages (ex. mercredi après-midi).
        case allowedOnlyDuring
    }

    public var mode: Mode
    public var windows: [TimeWindow]

    public init(mode: Mode = .allowed, windows: [TimeWindow] = []) {
        self.mode = mode; self.windows = windows
    }

    public func isBlocked(at date: Date, calendar: Calendar = .current) -> Bool {
        switch mode {
        case .allowed: return false
        case .blocked: return true
        case .blockedDuring: return windows.contains { $0.contains(date, calendar: calendar) }
        case .allowedOnlyDuring: return !windows.contains { $0.contains(date, calendar: calendar) }
        }
    }

    /// Plage proposée quand on passe en mode horaire.
    public static func defaultWindow(for mode: Mode) -> TimeWindow {
        mode == .allowedOnlyDuring
            ? TimeWindow(days: [3, 6, 7], start: 14 * 60, end: 18 * 60)   // mercredi, samedi, dimanche 14 h–18 h
            : TimeWindow(days: TimeWindow.allDays, start: 21 * 60, end: 7 * 60)   // la nuit
    }
}

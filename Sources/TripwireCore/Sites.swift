import Foundation

public enum Sites {
    /// The watched domains. A subdomain of one of these also matches.
    public static let watched = ["x.com", "twitter.com", "linkedin.com", "reddit.com", "instagram.com"]

    /// Hosts handed to SelfControl. Explicit common subdomains, in case
    /// SelfControl's own subdomain handling misses one.
    public static let blocklist: [String] = watched.flatMap { ["\($0)", "www.\($0)"] }
        + ["mobile.twitter.com", "mobile.x.com", "old.reddit.com", "new.reddit.com"]

    /// Post composer pages (D17). Being on one pauses the clock.
    /// LinkedIn checked on the live site; X and Reddit from their URL scheme.
    static let composers = ["linkedin.com/sharing/compose", "linkedin.com/post/new", "x.com/compose/", "twitter.com/compose/", "reddit.com/submit"]

    /// True when `url` is a post composer on a watched site.
    public static func isComposer(url: String) -> Bool {
        guard let u = URL(string: url), let host = u.host?.lowercased(), match(url: url) != nil else { return false }
        let page = (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + u.path.lowercased()
        return composers.contains { page.hasPrefix($0) }
    }

    /// The watched domain that `url` belongs to, or nil.
    public static func match(url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        return watched.first { host == $0 || host.hasSuffix("." + $0) }
    }
}

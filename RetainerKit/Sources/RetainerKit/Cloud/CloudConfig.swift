import Foundation

/// Where the account and the cloud copy of the notes live.
///
/// Sign-in happens on the website; the notes' cloud copy is a Supabase
/// project: a table of records, a bucket of pictures, both closed to
/// everyone but the person they belong to. Neither value here is a secret:
/// the key names the project and gives nothing on its own.
public struct CloudConfig: Sendable, Equatable {

    /// The Supabase project.
    public var server: URL
    /// The project's publishable key, sent with every request.
    public var key: String
    /// The website, which has the sign-in page at `login/`.
    public var site: URL

    public init(server: URL, key: String, site: URL) {
        self.server = server
        self.key = key
        self.site = site
    }

    public static let standard = CloudConfig(
        server: URL(string: "https://hzcmlliwxauqzhkpxzfw.supabase.co")!,
        key: "sb_publishable_3gd1VzZxn53M9I5WjyFJhw_XpIVAsdO",
        site: URL(string: "https://retainer.onrender.com/")!)

    /// The address the app is opened with when sign-in is over.
    public static let callbackScheme = "retainer"

    /// The sign-in page, carrying the challenge that ties the sign-in to
    /// this copy of the app.
    public func signInPage(challenge: String) -> URL {
        var parts = URLComponents(url: site.appendingPathComponent("login/"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "challenge", value: challenge)]
        return parts.url!
    }
}

//
//  GitHubReleaseChecker.swift
//  Face ID
//
//  Talks to the GitHub Releases API so "Check for Updates" works without a
//  hosted Sparkle appcast. Fetches the latest published release, compares its
//  tag to the running build's version, and exposes the .dmg asset URL so the
//  updater can download and mount it.
//

import Foundation

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String?
    let assets: [GitHubAsset]
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
        case prerelease
    }

    /// The version with any leading "v"/"V" stripped, e.g. "v1.2" -> "1.2".
    var version: String { tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) }

    /// First asset whose name ends in ".dmg" — the install package we install from.
    var dmgURL: URL? {
        guard let asset = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
            return nil
        }
        return URL(string: asset.downloadURL)
    }
}

struct GitHubAsset: Decodable {
    let name: String
    let downloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
    }
}

enum GitHubUpdateError: LocalizedError {
    case httpStatus(Int)
    case invalidResponse
    case noDMGAsset(String)
    case downloadFailed(Error)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "GitHub 返回了错误状态码 \(code)。"
        case .invalidResponse: return "无法解析 GitHub 的返回数据。"
        case .noDMGAsset(let tag): return "GitHub 上版本 \(tag) 没有找到 .dmg 安装包。"
        case .downloadFailed(let error): return "下载失败：\(error.localizedDescription)"
        }
    }
}

enum GitHubReleaseChecker {
    static let repo = "joe0515/face-id"
    private static let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    /// The running app's short version string, e.g. "1.1".
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    static func fetchLatestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: apiURL)
        // GitHub's API rejects requests without a User-Agent.
        request.setValue("Face-ID-Mac", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GitHubUpdateError.httpStatus(http.statusCode)
        }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw GitHubUpdateError.invalidResponse
        }
        return release
    }

    /// True when `latest` is a newer semantic version than `current`. Numeric
    /// component comparison so "1.10" > "1.9" (lexicographic would say false).
    static func isUpdateAvailable(latest: String, current: String = currentVersion) -> Bool {
        let l = latest.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        guard !l.isEmpty else { return false }
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv > cv { return true }
            if lv < cv { return false }
        }
        return false
    }
}

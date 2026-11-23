//
//  ModReadmePlanner.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation

/// What the planner worked out for a repo that has no preset.
public struct ModInstallPlan: Sendable, Hashable {
    public var asset: GitHubRelease.Asset
    public var rule: ModInstallRule
    /// The README lines the plan is based on, shown to the user before installing.
    public var reasons: [String]
    /// Whether the README said clearly how to install, rather than the planner guessing.
    public var confident: Bool
    /// What the mod needs installed alongside it.
    public var dependencies = ModDependencies()
}

/// Things a mod says it needs: other mods on GitHub and Windows runtimes.
public struct ModDependencies: Sendable, Hashable {
    /// Other mods, as `owner/name`, to install from their latest release.
    public var repos: [String] = []
    /// Winetricks verbs for Windows runtimes (Visual C++, .NET, …).
    public var runtimeVerbs: [String] = []
    /// Needs a mod loader (BepInEx) the archive doesn't include.
    public var needsBepInEx = false

    public init() {}

    public var isEmpty: Bool { repos.isEmpty && runtimeVerbs.isEmpty && !needsBepInEx }

    static let runtimeKeywords: [(keys: [String], verb: String)] = [
        (["visual c++", "vc++", "vcredist", "vc_redist", "msvc runtime"], "vcrun2022"),
        ([".net framework 4.8", "dotnet 4.8", "net48"], "dotnet48"),
        ([".net framework 4.7", "dotnet 4.7"], "dotnet472"),
        (["xna framework", "xna 4"], "xna40"),
        (["d3dcompiler_47"], "d3dcompiler_47")
    ]

    /// Reads dependencies out of release notes and README text.
    public static func find(in text: String, selfRepo: String?, assetNames: [String]) -> ModDependencies {
        var found = ModDependencies()
        let lower = text.lowercased()
        for entry in runtimeKeywords where entry.keys.contains(where: lower.contains) {
            if !found.runtimeVerbs.contains(entry.verb) { found.runtimeVerbs.append(entry.verb) }
        }

        // GitHub links on lines that talk about requirements.
        let cues = ["require", "depend", "needs", "need ", "prerequisite", "install first", "built on", "uses "]
        for line in text.components(separatedBy: .newlines) {
            let lowerLine = line.lowercased()
            guard cues.contains(where: lowerLine.contains) else { continue }
            for slug in githubSlugs(in: line) where slug.lowercased() != selfRepo?.lowercased() {
                if !found.repos.contains(where: { $0.lowercased() == slug.lowercased() }) { found.repos.append(slug) }
            }
        }

        let bundlesLoader = assetNames.contains { $0.lowercased().contains("bepinex") }
        let talksLoader = lower.contains("requires bepinex") || lower.contains("bepinex is required")
            || lower.contains("install bepinex")
        found.needsBepInEx = talksLoader && !bundlesLoader
        return found
    }

    static func githubSlugs(in line: String) -> [String] {
        let pattern = #"github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            Range(match.range(at: 1), in: line).flatMap { ModPreset.repoSlug(from: String(line[$0])) }
        }
        .filter { !["releases", "issues", "blob", "tree", "wiki"].contains($0.split(separator: "/").last ?? "") }
    }
}

/// Turns a mod's README and release files into install steps.
///
/// It looks for the usual phrasing ("extract into your game folder",
/// "put the .dll in BepInEx/plugins", "make a copy of the game") and falls
/// back to the shape of the release files. The result is always shown to the
/// user before anything is written.
public enum ModReadmePlanner {
    /// Reads the latest release's notes first, then the README, so steps that
    /// changed with a release win over older README text.
    public static func plan(readme: String?, release: GitHubRelease, repo: String? = nil) -> ModInstallPlan? {
        let text = [release.body, readme].compactMap { $0 }.joined(separator: "\n")
        let sentences = text
            .components(separatedBy: CharacterSet(charactersIn: "\n.!"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func evidence(_ keys: [String]) -> String? {
            sentences.first { line in keys.allSatisfy { line.lowercased().contains($0) } }
        }

        var reasons: [String] = []
        var confident = false

        // Better detection of BepInEx plugin instructions:
        // - "put the .dll in BepInEx/plugins"
        // - "copy to BepInEx/plugins"
        // - "extract to BepInEx/plugins"
        // - any mention of "plugins" folder alongside DLL/zip context
        let pluginLine = evidence(["bepinex", "plugins"])
        let pluginFolderLine = evidence(["plugins"]) // standalone "plugins" folder mention
        let extractLine = evidence(["extract"]) ?? evidence(["unzip"])
        let copyLine = evidence(["copy", "folder"]) ?? evidence(["duplicate", "folder"])
        let dllLine = evidence([".dll"]) // explicit DLL mention
        let wantsCopy = copyLine.map { line in
            let line = line.lowercased()
            return line.contains("game") || line.contains("among us") || line.contains("install")
        } ?? false

        // Determine if this looks like a BepInEx plugin mod
        let isLikelyBepInExPlugin = (pluginLine != nil)
            || (pluginFolderLine != nil && (dllLine != nil || !isZip))
            || (dllLine != nil && (extractLine == nil || pluginFolderLine != nil))

        guard let asset = pickAsset(release.assets, preferDLL: isLikelyBepInExPlugin && extractLine == nil) else {
            return nil
        }
        let isZip = asset.name.lowercased().hasSuffix(".zip")

        var rule: ModInstallRule
        if !isZip {
            // Single DLL file - if it looks like a BepInEx plugin, put in plugins folder
            rule = ModInstallRule(mode: .copyFile, subpath: isLikelyBepInExPlugin ? "BepInEx/plugins" : "")
            if let pluginLine { reasons.append(pluginLine); confident = true }
            else if let pluginFolderLine { reasons.append(pluginFolderLine); confident = true }
            else if let dllLine { reasons.append(dllLine) }
        } else {
            // ZIP file - check if it's a plugin bundle (talks about plugins but not general extract)
            let subpath = (isLikelyBepInExPlugin && extractLine == nil) ? "BepInEx/plugins" : ""
            rule = ModInstallRule(mode: .extract, subpath: subpath)
            if let extractLine { reasons.append(extractLine); confident = true }
            if subpath.isEmpty == false {
                if let pluginLine { reasons.append(pluginLine) }
                else if let pluginFolderLine { reasons.append(pluginFolderLine) }
            }
        }
        if wantsCopy, let copyLine {
            rule.copyGame = true
            reasons.append(copyLine)
        }
        if reasons.isEmpty {
            reasons.append("No install steps found in the README; guessing from the release file \(asset.name).")
        }
        let dependencies = ModDependencies.find(
            in: text, selfRepo: repo, assetNames: release.assets.map(\.name)
        )
        return ModInstallPlan(
            asset: asset, rule: rule, reasons: reasons, confident: confident, dependencies: dependencies
        )
    }

    /// The release file most likely meant for a Windows game on Steam.
    static func pickAsset(_ assets: [GitHubRelease.Asset], preferDLL: Bool) -> GitHubRelease.Asset? {
        func score(_ asset: GitHubRelease.Asset) -> Int {
            let name = asset.name.lowercased()
            var score = 0
            if name.hasSuffix(".zip") { score += preferDLL ? 5 : 20 }
            if name.hasSuffix(".dll") { score += preferDLL ? 20 : 5 }
            if name.contains("steam") { score += 10 }
            if name.contains("x64") || name.contains("win") { score += 4 }
            for bad in ["android", "ios", "linux", "mac", "itch", "msstore", "source", "debug", "x86"]
            where name.contains(bad) {
                score -= name.contains("steam") && bad == "msstore" ? 0 : 15
            }
            return score
        }
        return assets
            .filter { [".zip", ".dll"].contains(where: $0.name.lowercased().hasSuffix) }
            .max { score($0) < score($1) }
    }
}

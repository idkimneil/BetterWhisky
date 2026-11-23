//
//  ModsSectionView.swift
//  Whisky
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

// swiftlint:disable file_length
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// The Mods section on a program's page: presets, mods from any GitHub repo,
/// and a drop target for local `.zip` and `.dll` files.
struct ModsSectionView: View { // swiftlint:disable:this type_body_length
    @ObservedObject var program: Program
    @Binding var isExpanded: Bool

    @State private var installed: [InstalledMod] = []
    @State private var latestVersions: [String: GitHubRelease] = [:]
    @State private var busy: String?
    @State private var repoInput = ""
    @State private var pendingPlan: PendingPlan?
    @State private var message: String?
    @State private var dropTargeted = false
    @State private var activeMod: URL?
    @State private var showAddSheet = false
    @State private var launchRequest: LaunchRequest?
    @Binding var modsChanged: Int

    struct PendingPlan: Identifiable {
        let id = UUID()
        let repo: String
        let release: GitHubRelease
        let plan: ModInstallPlan
    }

    private var gameFolder: URL { program.url.deletingLastPathComponent() }
    private var presets: [ModPreset] { ModPreset.presets(for: program.url) }

    var body: some View {
        Section(isExpanded: $isExpanded) {
            ForEach(presets) { preset in
                presetRow(preset)
            }
            ForEach(installed.filter { mod in !presets.contains { $0.repo == mod.repo } }) { mod in
                otherModRow(mod)
            }
            addRow
            if busy != nil || message != nil {
                statusRow
            }
        } header: {
            Text("Mods")
        }
        .task(id: program.url) { await refresh() }
        .sheet(isPresented: $showAddSheet) { addSheet }
        .sheet(item: $launchRequest) { request in
            LaunchProgressView(request: request) { launchRequest = nil }
        }
        .sheet(item: $pendingPlan) { pending in
            planSheet(pending)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func presetRow(_ preset: ModPreset) -> some View {
        let release = latestVersions[preset.repo]
        let current = installedPreset(preset)
        let isOn = current.map { isActive($0.folder) } ?? false
        let update = release.flatMap { release in
            current.flatMap { $0.mod.version == release.tagName ? nil : release.tagName }
        }
        let canToggle = preset.install.ownFolder || preset.install.frozenCopy || preset.install.copyGame
        HStack(spacing: 12) {
            modIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(preset.name)
                    if isOn {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("On").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Group {
                    if let current {
                        Text(update.map { "Version \(current.mod.version) · \($0) available" }
                            ?? "Version \(current.mod.version)")
                    } else if let release {
                        Text("Latest \(release.tagName)")
                    } else {
                        Text(verbatim: preset.repo)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if current == nil, let release, release.isStale {
                    Label("Last release is over six months old", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("It may not work with the current version of the game.")
                }
            }
            Spacer(minLength: 12)
            if canToggle {
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        if newValue, let current {
                            switchOn(current.folder)
                        } else {
                            turnOffMods()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .disabled(busy != nil || current == nil)
                .help(isOn ? "Turn off this mod" : "Turn on this mod")
            }
            presetActions(preset, current: current, isOn: isOn, update: update)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func presetActions(
        _ preset: ModPreset, current: (mod: InstalledMod, folder: URL)?, isOn: Bool, update: String?
    ) -> some View {
        if let current {
            let canToggle = preset.install.ownFolder || preset.install.frozenCopy || preset.install.copyGame
            if isOn {
                Button("Play") { play(preset, modFolder: current.folder) }
                    .disabled(busy != nil)
            } else if canToggle {
                Button("Turn On") { switchOn(current.folder) }
                    .disabled(busy != nil)
            }
            Menu {
                if let update {
                    Button("Update to \(update)") { installPreset(preset) }
                }
                if isOn {
                    Button("Turn Off") { turnOffMods() }
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([current.folder])
                }
                Divider()
                Button("Remove", role: .destructive) { remove(current.mod, in: current.folder) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(busy != nil)
        } else {
            Button("Install") { installPreset(preset) }
                .disabled(busy != nil)
        }
    }

    private func otherModRow(_ mod: InstalledMod) -> some View {
        HStack(spacing: 12) {
            modIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(mod.name)
                Text("Version \(mod.version)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Menu {
                Button("Remove", role: .destructive) { remove(mod) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private var modIcon: some View {
        Image(systemName: "puzzlepiece.extension")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Add from GitHub, or drop a file anywhere on the row.
    private var addRow: some View {
        HStack(spacing: 12) {
            Button("Add from GitHub…", systemImage: "link") { showAddSheet = true }
                .disabled(busy != nil)
            Spacer()
            Label("Drop a .zip or .dll", systemImage: "arrow.down.doc")
                .font(.caption)
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, dropTargeted ? 8 : 0)
        .background {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4]))
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in installDropped(url) }
                }
            }
            return !providers.isEmpty
        }
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let busy {
                ProgressView().controlSize(.small)
                Text(busy)
            } else if let message {
                Image(systemName: "info.circle")
                Text(message).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Dismiss", systemImage: "xmark") { self.message = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a mod from GitHub").font(.headline)
            Text("BetterWhisky reads the latest release and its install steps, and shows you the plan first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Repository", text: $repoInput, prompt: Text(verbatim: "owner/repo or a GitHub link"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(planFromGitHub)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showAddSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: planFromGitHub)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ModPreset.repoSlug(from: repoInput) == nil || busy != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func planSheet(_ pending: PendingPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \(pending.repo)?").font(.headline)
            Text("Release \(pending.release.tagName), file \(pending.plan.asset.name)")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(describe(pending.plan.rule)).bold()
                ForEach(pending.plan.reasons, id: \.self) { reason in
                    Text(verbatim: "“\(reason)”").font(.callout).foregroundStyle(.secondary)
                }
            }
            let deps = pending.plan.dependencies
            if !deps.isEmpty {
                Text("Also installs: " + (deps.repos + deps.runtimeVerbs).joined(separator: ", "))
                    .font(.callout)
            }
            if !pending.plan.confident {
                Text("The README didn't say clearly how to install this, so this is a guess.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { pendingPlan = nil }
                Button("Install") {
                    pendingPlan = nil
                    install(
                        asset: pending.plan.asset, release: pending.release,
                        name: pending.repo.components(separatedBy: "/").last ?? pending.repo,
                        repo: pending.repo, rule: pending.plan.rule, dependencies: pending.plan.dependencies
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func describe(_ rule: ModInstallRule) -> String {
        let place = rule.subpath.isEmpty ? "the game folder" : rule.subpath
        let action = rule.mode == .extract ? "Unzip into \(place)" : "Copy the file into \(place)"
        return rule.copyGame ? "\(action) of a new copy of the game" : action
    }

    // MARK: Actions

    /// A preset may live in a copy of the game folder rather than this one.
    private func installedPreset(_ preset: ModPreset) -> (mod: InstalledMod, folder: URL)? {
        var folders = [gameFolder]
        if preset.install.frozenCopy {
            folders.insert(ModInstaller.modFolder(for: preset.name, game: gameFolder).appending(path: "game"), at: 0)
        } else if preset.install.ownFolder || preset.install.frozenCopy {
            folders.insert(ModInstaller.modFolder(for: preset.name, game: gameFolder), at: 0)
        } else if preset.install.copyGame, let copy = try? copyFolder(for: preset.name) {
            folders.insert(copy, at: 0)
        }
        for folder in folders {
            if let mod = ModInstaller.installedMods(in: folder).first(where: { $0.repo == preset.repo }) {
                return (mod, folder)
            }
        }
        return nil
    }

    /// The Steam app this game is, from its presets.
    private var steamAppId: Int? { presets.first { $0.steamAppId != nil }?.steamAppId }

    /// A mod's frozen copy of the game lives in `<Game> Mods/<Mod>/game`.
    private func isFrozenCopy(_ folder: URL) -> Bool {
        folder.lastPathComponent == "game" && folder != gameFolder
    }

    private func copyFolder(for modName: String) throws -> URL {
        gameFolder.deletingLastPathComponent()
            .appending(path: "\(gameFolder.lastPathComponent) - \(ModInstaller.safeName(modName))")
    }

    private func refresh() async {
        installed = ModInstaller.installedMods(in: gameFolder)
        if let appId = steamAppId,
           let selected = SteamModLauncher.selected(appId: appId, bottleURL: program.bottle.url) {
            activeMod = selected.deletingLastPathComponent()
        } else {
            activeMod = ModLoaderRedirect.activeModFolder(gameFolder: gameFolder, bottleURL: program.bottle.url)
        }
        modsChanged += 1
        for preset in presets where latestVersions[preset.repo] == nil {
            latestVersions[preset.repo] = try? await GitHubReleases.latestRelease(repo: preset.repo)
        }
    }

    /// Gets the latest release, then reads that release's notes and the README
    /// for install steps. The preset only fills in what they don't say: which
    /// file to take, and whether to install into a copy of the game.
    private func installPreset(_ preset: ModPreset) {
        Task {
            busy = "Checking \(preset.name)…"
            defer { busy = nil }
            do {
                async let readme = GitHubReleases.readme(repo: preset.repo)
                let release = try await GitHubReleases.latestRelease(repo: preset.repo)
                latestVersions[preset.repo] = release
                let readmeText = try? await readme
                let plan = ModReadmePlanner.plan(readme: readmeText, release: release, repo: preset.repo)
                guard let asset = release.assets.first(where: { preset.matchesAsset(named: $0.name) })
                    ?? plan?.asset else {
                    message = "\(preset.name) \(release.tagName) has no file to install."
                    return
                }
                var rule = preset.install
                if let plan, plan.confident, plan.asset == asset {
                    rule = plan.rule
                    rule.copyGame = rule.copyGame || preset.install.copyGame
                    rule.ownFolder = preset.install.ownFolder
                    rule.frozenCopy = preset.install.frozenCopy
                }
                if preset.install.frozenCopy,
                   !prepareFrozenCopy(for: preset, release: release, readme: readmeText) {
                    return
                }
                install(
                    asset: asset, release: release, name: preset.name, repo: preset.repo,
                    rule: rule, dependencies: plan?.dependencies ?? ModDependencies()
                )
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Decides whether this release can go in, by the game version it needs:
    /// a fresh copy of the current game, the frozen copy as it is, or not at all.
    private func prepareFrozenCopy(for preset: ModPreset, release: GitHubRelease, readme: String?) -> Bool {
        let text = [release.body, readme].compactMap { $0 }.joined(separator: "\n")
        let required = ModGameVersion.required(in: text, modVersion: release.tagName)
        let game = ModGameVersion.installed(gameFolder: gameFolder)
        let copy = ModInstaller.modFolder(for: preset.name, game: gameFolder).appending(path: "game")
        let hasCopy = FileManager.default.fileExists(atPath: copy.path(percentEncoded: false))
        switch ModGameVersion.decide(
            required: required, game: game, copy: hasCopy ? ModInstaller.frozenVersion(copy) : nil, hasCopy: hasCopy
        ) {
        case .blocked(let required, let game):
            message = "\(preset.name) \(release.tagName) needs Among Us \(required), and this is \(game). "
                + "Wait for a mod update that supports \(game)."
            return false
        case .keep(let required):
            message = "\(preset.name) \(release.tagName) is for Among Us \(required). Keeping the version you have."
            return false
        case .install(let freshCopy):
            if freshCopy, hasCopy {
                if let appId = steamAppId, SteamModLauncher.selected(appId: appId, bottleURL: program.bottle.url)?
                    .path.hasPrefix(copy.path) == true {
                    try? SteamModLauncher.select(nil, appId: appId, bottleURL: program.bottle.url)
                }
                try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            }
            return true
        }
    }

    private func planFromGitHub() {
        guard let repo = ModPreset.repoSlug(from: repoInput) else { return }
        Task {
            busy = "Reading \(repo) on GitHub…"
            defer { busy = nil }
            do {
                async let readme = GitHubReleases.readme(repo: repo)
                let release = try await GitHubReleases.latestRelease(repo: repo)
                guard let plan = ModReadmePlanner.plan(readme: try await readme, release: release, repo: repo) else {
                    message = "\(repo) \(release.tagName) has no .zip or .dll to install."
                    return
                }
                showAddSheet = false
                pendingPlan = PendingPlan(repo: repo, release: release, plan: plan)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func install(
        asset: GitHubRelease.Asset, release: GitHubRelease, name: String, repo: String,
        rule: ModInstallRule, dependencies: ModDependencies = ModDependencies()
    ) {
        Task {
            busy = "Installing \(name) \(release.tagName)…"
            defer { busy = nil }
            do {
                let result = try await ModInstaller.install(
                    asset: asset, version: release.tagName, name: name, repo: repo,
                    rule: rule, gameExecutable: program.url
                )
                let notes = await installDependencies(dependencies, into: result, seen: [repo.lowercased()])
                if isFrozenCopy(result.gameFolder), let preset = presets.first(where: { $0.repo == repo }) {
                    await preset.downloadLogo(into: result.gameFolder.deletingLastPathComponent())
                }
                finished(result, notes: notes)
                await connectAccount(forMod: name)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// The last setup step for mods that need the game's account (Town of
    /// Us): the plain game's one-time sign-in, so Play opens the mod
    /// straight away later. Play does it too if this is skipped.
    private func connectAccount(forMod name: String) async {
        guard let preset = ModPreset.named(name), preset.accountSave != nil,
              let appId = preset.steamAppId else { return }
        busy = "Connecting your game account…"
        defer { busy = nil }
        let ready = await ModAccountPrimer.prepare(
            appId: appId, gameFolder: gameFolder, modName: name, bottle: program.bottle
        )
        if !ready {
            message = (message.map { $0 + " " } ?? "")
                + "Your game account isn't connected yet; it will be the first time you press Play."
        }
    }

    private func installDropped(_ file: URL) {
        Task {
            busy = "Installing \(file.lastPathComponent)…"
            defer { busy = nil }
            do {
                finished(try await ModInstaller.installLocal(file: file, gameExecutable: program.url))
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func finished(_ result: ModInstallResult, notes: [String] = []) {
        useModLoader(in: result)
        if isFrozenCopy(result.gameFolder) {
            switchOn(result.gameFolder)
            let version = ModInstaller.frozenVersion(result.gameFolder).map { " for Among Us \($0)" } ?? ""
            message = "Installed \(result.mod.name)\(version). It's in the Library as its own game. "
                + "The first start takes a few minutes."
        } else if result.executable == program.url, result.gameFolder != gameFolder {
            // A mod in its own folder: switch the game's loader over to it.
            do {
                try ModLoaderRedirect.activate(
                    modFolder: result.gameFolder, gameFolder: gameFolder, bottleURL: program.bottle.url
                )
                message = "Installed \(result.mod.name). Press Play to start it through Steam. "
                    + "The first launch can take a few minutes."
            } catch {
                message = "Installed \(result.mod.name), but couldn't switch it on: \(error.localizedDescription)"
            }
        } else if result.gameFolder != gameFolder {
            // The mod went into a copy of the game: pin the copy so it has its own launch button.
            let bottle = program.bottle
            if !bottle.settings.pins.contains(where: { $0.url == result.executable }) {
                bottle.settings.pins.append(PinnedProgram(
                    name: "\(program.name.replacingOccurrences(of: ".exe", with: "")) (\(result.mod.name))",
                    url: result.executable
                ))
            }
            message = "Installed \(result.mod.name) into “\(result.gameFolder.lastPathComponent)”. "
                + "It's pinned in the bottle. The first launch can take a few minutes."
        } else {
            message = "Installed \(result.mod.name) (\(result.mod.files.count) files)."
        }
        if !notes.isEmpty, let current = message {
            message = ([current] + notes).joined(separator: "\n")
        }
        Task { await refresh() }
    }

    /// Switches the loader to `modFolder` (or off, for nil) and starts the
    /// game the way its preset says: through Steam for Steam games, whose
    /// sign-in only works when Steam launches them.
    private func play(_ preset: ModPreset, modFolder: URL?) {
        if let appId = preset.steamAppId, modFolder.map(isFrozenCopy) ?? true, preset.install.frozenCopy {
            Task {
                do {
                    busy = modFolder == nil ? nil : "Getting Steam ready…"
                    defer { busy = nil }
                    let steamWasRunning = await SteamModLauncher.isSteamRunning()
                    let started = Date()
                    if let modFolder {
                        SteamModLauncher.ensureLoaderOverride(gameExecutable: program.url, bottle: program.bottle)
                        try await SteamModLauncher.prepare(appId: appId, bottle: program.bottle)
                        try SteamModLauncher.select(
                            ModInstaller.mainExecutable(in: modFolder, preferring: program.name),
                            appId: appId, bottleURL: program.bottle.url
                        )
                    } else {
                        try SteamModLauncher.select(nil, appId: appId, bottleURL: program.bottle.url)
                    }
                    try SteamLauncher.launch(appId: appId, bottle: program.bottle)
                    message = nil
                    launchRequest = makeLaunchRequest(
                        preset, appId: appId, modFolder: modFolder, steamWasRunning: steamWasRunning, started: started
                    )
                } catch {
                    message = error.localizedDescription
                }
                await refresh()
            }
            return
        }
        do {
            if let modFolder {
                try ModLoaderRedirect.activate(
                    modFolder: modFolder, gameFolder: gameFolder, bottleURL: program.bottle.url
                )
            } else {
                try ModLoaderRedirect.deactivate(gameFolder: gameFolder)
            }
            if preset.launch == .steam, let appId = preset.steamAppId {
                try SteamLauncher.launch(appId: appId, bottle: program.bottle)
                message = "Starting \(modFolder == nil ? program.name : preset.name) through Steam…"
            } else {
                program.run()
            }
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    private func makeLaunchRequest(
        _ preset: ModPreset, appId: Int, modFolder: URL?, steamWasRunning: Bool, started: Date
    ) -> LaunchRequest {
        let root = SteamLibrary.detectInstall(bottleURL: program.bottle.url)
        return LaunchRequest(
            title: program.name.replacingOccurrences(of: ".exe", with: ""),
            modName: modFolder == nil ? nil : preset.name,
            artworkURL: root.flatMap { SteamLibrarySource.artworkURL(appID: appId, steamRoot: $0) },
            monitor: ModLaunchMonitor(
                bottleURL: program.bottle.url, appId: appId,
                gameFolder: modFolder ?? gameFolder, modded: modFolder != nil, startedAt: started
            ),
            steamWasRunning: steamWasRunning
        )
    }

    private func isActive(_ folder: URL) -> Bool {
        if isFrozenCopy(folder) {
            return activeMod?.standardizedFileURL.path == folder.standardizedFileURL.path
        }
        return activeMod != nil
            && ModLoaderRedirect.pointsAt(folder, gameFolder: gameFolder, bottleURL: program.bottle.url)
    }

    private func switchOn(_ folder: URL) {
        if isFrozenCopy(folder), let appId = steamAppId {
            do {
                try SteamModLauncher.select(
                    ModInstaller.mainExecutable(in: folder, preferring: program.name),
                    appId: appId, bottleURL: program.bottle.url
                )
            } catch {
                message = error.localizedDescription
            }
            Task { await refresh() }
            return
        }
        do {
            try ModLoaderRedirect.activate(modFolder: folder, gameFolder: gameFolder, bottleURL: program.bottle.url)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    private func turnOffMods() {
        do {
            if let appId = steamAppId {
                try SteamModLauncher.select(nil, appId: appId, bottleURL: program.bottle.url)
            }
            try ModLoaderRedirect.deactivate(gameFolder: gameFolder)
            message = nil
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }

    /// Installs what a mod needs: other mods from their latest releases (into
    /// the same game folder, following their own install steps), BepInEx if
    /// required, and Windows runtimes through winetricks. Returns a line per
    /// dependency for the user.
    private func installDependencies(
        _ deps: ModDependencies, into result: ModInstallResult, seen: Set<String>, depth: Int = 0
    ) async -> [String] {
        var notes: [String] = []
        var seen = seen
        if deps.needsBepInEx, !ModInstaller.hasBepInEx(result.gameFolder) {
            // Install BepInEx from its GitHub releases
            do {
                let bepInExNotes = try await installBepInEx(into: result.gameFolder)
                notes += bepInExNotes
            } catch {
                notes.append("Failed to install BepInEx: \(error.localizedDescription)")
            }
        }
        for repo in deps.repos where depth < 3 && !seen.contains(repo.lowercased()) {
            seen.insert(repo.lowercased())
            let name = repo.components(separatedBy: "/").last ?? repo
            let present = ModInstaller.installedMods(in: result.gameFolder)
            if present.contains(where: { $0.repo.lowercased() == repo.lowercased() })
                || ModInstaller.bundles(plugin: name, in: result.gameFolder) {
                continue
            }
            busy = "Installing dependency \(repo)…"
            do {
                async let readme = GitHubReleases.readme(repo: repo)
                let release = try await GitHubReleases.latestRelease(repo: repo)
                guard let plan = ModReadmePlanner.plan(readme: try? await readme, release: release, repo: repo) else {
                    notes.append("Dependency \(repo) has nothing to install.")
                    continue
                }
                var rule = plan.rule
                rule.copyGame = false
                if plan.asset.name.lowercased().hasSuffix(".dll"), ModInstaller.hasBepInEx(result.gameFolder) {
                    rule.subpath = "BepInEx/plugins"
                }
                // Into the mod's folder, next to the loader it plugs into.
                _ = try await ModInstaller.install(
                    asset: plan.asset, version: release.tagName, name: name, repo: repo,
                    rule: rule, gameExecutable: result.gameFolder.appending(path: result.executable.lastPathComponent)
                )
                notes.append("Installed dependency \(name) \(release.tagName).")
                notes += await installDependencies(plan.dependencies, into: result, seen: seen, depth: depth + 1)
            } catch {
                notes.append("Dependency \(repo) failed: \(error.localizedDescription)")
            }
        }
        notes += await installRuntimes(deps.runtimeVerbs)
        return notes
    }

    /// Installs BepInEx from GitHub releases into the game folder.
    /// Returns notes about what was installed.
    private func installBepInEx(into gameFolder: URL) async throws -> [String] {
        var notes: [String] = []
        let repo = "BepInEx/BepInEx"
        busy = "Installing BepInEx…"
        defer { busy = nil }
        async let readme = GitHubReleases.readme(repo: repo)
        let release = try await GitHubReleases.latestRelease(repo: repo)
        guard let plan = ModReadmePlanner.plan(readme: try? await readme, release: release, repo: repo),
              let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) ?? plan.asset else {
            throw NSError(domain: "ModInstaller", code: -1, userInfo: [NSLocalizedDescriptionKey: "No suitable BepInEx release asset found"])
        }
        var rule = plan.rule
        rule.copyGame = false
        // BepInEx goes into the game root (it creates BepInEx/ folder)
        rule.subpath = ""
        let result = try await ModInstaller.install(
            asset: asset, version: release.tagName, name: "BepInEx", repo: repo,
            rule: rule, gameExecutable: gameFolder.appending(path: program.url.lastPathComponent)
        )
        notes.append("Installed BepInEx \(release.tagName).")
        // Ensure the winhttp.dll override is set for the game
        useModLoader(in: result)
        return notes
    }

    /// Windows runtimes through winetricks, skipping a VC++ runtime that's already there.
    private func installRuntimes(_ verbs: [String]) async -> [String] {
        var notes: [String] = []
        for verb in verbs {
            if verb.hasPrefix("vcrun"), VCRedistDetector.isInstalled(prefixURL: program.bottle.url) { continue }
            busy = "Installing \(verb)…"
            var outcome = "\(verb) didn't finish."
            for await event in Winetricks.installVerb(verb, for: program.bottle) {
                switch event {
                case .completed(let code): outcome = code == 0 ? "Installed \(verb)." : "\(verb) failed (exit \(code))."
                case .failed(let reason): outcome = "\(verb) failed: \(reason)"
                default: break
                }
            }
            notes.append(outcome)
        }
        return notes
    }

    /// BepInEx and similar loaders ship their own winhttp.dll, which Wine
    /// ignores in favour of its built-in one unless the game is told otherwise.
    private func useModLoader(in result: ModInstallResult) {
        let loader = result.gameFolder.appending(path: "winhttp.dll")
        guard FileManager.default.fileExists(atPath: loader.path(percentEncoded: false)) else { return }
        if isFrozenCopy(result.gameFolder) {
            SteamModLauncher.ensureLoaderOverride(gameExecutable: program.url, bottle: program.bottle)
            return
        }
        let target = result.executable == program.url
            ? program : Program(url: result.executable, bottle: program.bottle)
        var overrides = target.settings.overrides ?? ProgramOverrides()
        var dlls = (overrides.dllOverrides ?? []).filter { $0.dllName.lowercased() != "winhttp" }
        dlls.append(DLLOverrideEntry(dllName: "winhttp", mode: .nativeThenBuiltin))
        overrides.dllOverrides = dlls
        target.settings.overrides = overrides
    }

    private func remove(_ mod: InstalledMod, in folder: URL? = nil) {
        do {
            let folder = folder ?? gameFolder
            if isFrozenCopy(folder) {
                if let appId = steamAppId, activeMod?.standardizedFileURL.path == folder.standardizedFileURL.path {
                    try SteamModLauncher.select(nil, appId: appId, bottleURL: program.bottle.url)
                }
                let modFolder = folder.deletingLastPathComponent()
                try FileManager.default.removeItem(at: modFolder)
                let modsRoot = modFolder.deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: modsRoot.path(percentEncoded: false)))?
                    .filter({ !$0.hasPrefix(".") }).isEmpty == true {
                    try? FileManager.default.removeItem(at: modsRoot)
                }
                message = "Removed \(mod.name)."
                Task { await refresh() }
                return
            }
            try ModInstaller.uninstall(mod, from: folder)
            if folder != gameFolder, folder.deletingLastPathComponent().lastPathComponent.hasSuffix(" Mods") {
                if ModLoaderRedirect.pointsAt(folder, gameFolder: gameFolder, bottleURL: program.bottle.url) {
                    try ModLoaderRedirect.remove(gameFolder: gameFolder)
                }
                try? FileManager.default.removeItem(at: folder)
                let modsRoot = folder.deletingLastPathComponent()
                if (try? FileManager.default.contentsOfDirectory(atPath: modsRoot.path(percentEncoded: false)))?
                    .filter({ !$0.hasPrefix(".") }).isEmpty == true {
                    try? FileManager.default.removeItem(at: modsRoot)
                }
            }
            message = "Removed \(mod.name)."
        } catch {
            message = error.localizedDescription
        }
        Task { await refresh() }
    }
}

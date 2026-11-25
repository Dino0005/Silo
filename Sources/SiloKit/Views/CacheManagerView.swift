import SwiftUI

/// Settings → General → Manage Caches…: every game's caches (`CacheInventory`), uninstalled games' included, each
/// with the space it takes and a Clear.
struct CacheManagerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @ViewState private var entries: [CacheInventory.Entry]?
    /// The entry waiting for the confirmation.
    @ViewState private var pending: CacheInventory.Entry?
    @ViewState private var message: String?
    @ViewState private var filter: Filter = .all

    enum Filter: Hashable, CaseIterable {
        case all, installed, notInstalled

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .installed: "cache.filter.installed"
            case .notInstalled: "cache.filter.notInstalled"
            }
        }

        func includes(_ entry: CacheInventory.Entry) -> Bool {
            switch self {
            case .all: true
            case .installed: entry.installed
            case .notInstalled: !entry.installed
            }
        }
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        NavigationStack {
            Group {
                if let entries {
                    if entries.isEmpty {
                        Text("No game has a cache.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        list(entries)
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for the games' caches…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Caches")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(width: 560, height: 520)
        .task { await reload() }
        .confirmationDialog(Text("Clear the caches of \(pending?.name ?? "")?"),
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                guard let entry = pending else { return }
                pending = nil
                Task { await clear(entry) }
            }
        } message: {
            Text("If the game is installed, its next launch compiles its shaders again: it loads slower and stutters for a while.")
        }
    }

    @ViewBuilder
    private func list(_ all: [CacheInventory.Entry]) -> some View {
        let entries = all.filter(filter.includes)
        Form {
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Section {
                if entries.isEmpty {
                    Text("No cache here.").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).lineLimit(1)
                            Text(details(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Text(size(entry.status.bytes)).foregroundStyle(.secondary).monospacedDigit()
                        Button("Clear…") { pending = entry }
                    }
                }
            } header: {
                Text("Total: \(size(entries.reduce(0) { $0 + $1.status.bytes }))")
            } footer: {
                Text("A game's shaders as Metal compiled them (one cache for launches from Silo, one for launches from Steam for macOS), Silo's pipeline cache, and D3DMetal's translation of them. Neither Steam nor Silo removes them when a game is uninstalled; games marked Not installed only take space. D3DMetal's cache is shared with CrossOver and any other app that uses GPTK, so clearing it makes them translate the game's shaders again too; the ones no game in the library owns are listed by executable name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message {
                Section { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func details(_ entry: CacheInventory.Entry) -> String {
        let kinds: [(ShaderCache.Kind, String)] = [
            (.silo, String(localized: "Silo")), (.steam, String(localized: "Steam for macOS")),
            (.pipelines, String(localized: "pipelines")), (.translation, String(localized: "D3DMetal")),
        ]
        let parts = kinds.filter { entry.status[$0.0].bytes > 0 }
            .map { "\($0.1) \(size(entry.status[$0.0].bytes))" }.joined(separator: " · ")
        return entry.installed ? parts : String(localized: "Not installed") + " · " + parts
    }

    private func reload() async {
        let library = env.gameLibrary
        let steam = library.games.map { ($0.appID, $0.name, $0.installURL) }
        let manual = library.manualGames.map { ($0.id.uuidString, $0.name, $0.executablePath.lastPathComponent) }
        let paths = env.paths
        // Off the main actor: every installed game's folder is walked for its executables, some on an external drive.
        entries = await Task.detached {
            var games = steam.map { appID, name, install in
                CacheInventory.Game(id: String(appID), name: name,
                                    executables: ExecutableResolver.allExecutables(in: install)
                                        .map { ($0 as NSString).lastPathComponent })
            }
            games += manual.map { CacheInventory.Game(id: $0.0, name: $0.1, executables: [$0.2]) }
            // A left-behind game Silo made no app for is named from Steam for macOS's app cache, read once.
            let appInfo = try? AppInfoCache(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Steam/appcache/appinfo.vdf"))
            return CacheInventory.scan(games: games, hostAppsDir: paths.hostAppsDir, gameAppsDir: paths.gameAppsDir) { id in
                UInt32(id).flatMap { (try? appInfo?.app($0))??.info.map("common")?.string("name") }
            }
        }.value
    }

    private func clear(_ entry: CacheInventory.Entry) async {
        let outcome = await Task.detached { CacheInventory.clear(entry) }.value
        switch outcome {
        case .cleared(let freed): message = String(localized: "\(entry.name): freed \(size(freed)).")
        case .nothingToClear: message = nil
        case .inUse: message = String(localized: "\(entry.name) is running: quit it first.")
        case .failed(let reason): message = reason
        }
        await reload()
    }
}

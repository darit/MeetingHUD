import Foundation
import MLXLLM
import MLX
import MLXLMCommon

/// Manages MLX model lifecycle: discovery, download, load/unload, and memory pressure.
@Observable @MainActor
final class MLXModelManager {
    static let shared = MLXModelManager()

    // MARK: - State

    var availableModels: [MLXModelInfo] = []
    var selectedModel: MLXModelInfo?
    var loadState: LoadState = .unloaded
    var loadingStatusText: String = ""
    var downloadProgress: DownloadProgress?

    enum LoadState: Equatable {
        case unloaded
        case loading(progress: Double)
        case loaded
        case error(String)
    }

    struct DownloadProgress: Equatable {
        let modelId: String
        var progress: Double
        var downloadedBytes: UInt64
        var totalBytes: UInt64
    }

    // MARK: - Internal

    private(set) var modelContainer: ModelContainer?
    private(set) var modelConfiguration: ModelConfiguration?
    private var downloadTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    let systemRAM: UInt64 = ProcessInfo.processInfo.physicalMemory

    nonisolated private static let hfCacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface/hub")

    nonisolated private static let lmStudioModelsURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsFile = home.appendingPathComponent(".lmstudio/settings.json")
        if let data = try? Data(contentsOf: settingsFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let folder = json["downloadsFolder"] as? String {
            return URL(fileURLWithPath: folder)
        }
        return home.appendingPathComponent(".lmstudio/models")
    }()

    /// UserDefaults key for persisting selected model ID.
    nonisolated private static let selectedModelKey = "mlxSelectedModelId"

    nonisolated init() {
        setupMemoryPressureObserver()
    }

    /// Call once after app launch to discover available models.
    func initialScan() {
        scanForModels()
    }

    // MARK: - Memory Pressure

    nonisolated private func setupMemoryPressureObserver() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.unloadModel()
            }
        }
        source.resume()
        // Store the source on the main actor
        Task { @MainActor [weak self] in
            self?.memoryPressureSource = source
        }
    }

    // MARK: - Model Discovery

    func scanForModels() {
        Task.detached { [weak self] in
            guard let self else { return }
            let discovered = self.performScan()
            await MainActor.run {
                let discoveredByRepo = Dictionary(
                    discovered.map { ($0.repoId, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                var merged: [MLXModelInfo] = MLXModelInfo.recommended.map { rec in
                    discoveredByRepo[rec.repoId] ?? rec
                }
                for model in discovered {
                    if !merged.contains(where: { $0.repoId == model.repoId }) {
                        merged.append(model)
                    }
                }
                self.availableModels = merged

                let savedId = UserDefaults.standard.string(forKey: Self.selectedModelKey) ?? ""
                if !savedId.isEmpty {
                    self.selectedModel = merged.first { $0.repoId == savedId }
                }
            }
        }
    }

    nonisolated private func performScan() -> [MLXModelInfo] {
        var discovered = scanHuggingFaceCache(at: Self.hfCacheURL)
        discovered += scanLMStudioModels(at: Self.lmStudioModelsURL)
        return discovered
    }

    func isDownloaded(_ model: MLXModelInfo) -> Bool {
        if let localPath = model.localPath {
            return FileManager.default.fileExists(atPath: localPath)
        }
        return FileManager.default.fileExists(atPath: Self.modelCacheDir(for: model.repoId).path)
    }

    // MARK: - Download

    func downloadModel(_ model: MLXModelInfo) {
        downloadTask?.cancel()

        downloadProgress = DownloadProgress(
            modelId: model.repoId, progress: 0,
            downloadedBytes: 0, totalBytes: model.sizeOnDisk
        )

        downloadTask = Task {
            do {
                let config = ModelConfiguration(id: model.repoId)

                let container = try await LLMModelFactory.shared.loadContainer(
                    configuration: config
                ) { progress in
                    Task { @MainActor in
                        self.downloadProgress?.progress = progress.fractionCompleted
                        self.downloadProgress?.downloadedBytes = UInt64(
                            Double(model.sizeOnDisk) * progress.fractionCompleted
                        )
                    }
                }
                _ = container

                self.downloadProgress = nil
                self.scanForModels()
            } catch {
                self.downloadProgress = nil
                self.loadState = .error("Download failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = nil
    }

    // MARK: - Load / Unload

    func loadModel(_ model: MLXModelInfo) async throws {
        unloadModel()

        loadState = .loading(progress: 0)
        loadingStatusText = "Preparing \(model.name)…"
        selectedModel = model
        UserDefaults.standard.set(model.repoId, forKey: Self.selectedModelKey)

        let config: ModelConfiguration
        if let localPath = model.localPath {
            config = ModelConfiguration(directory: URL(fileURLWithPath: localPath))
            loadingStatusText = "Loading \(model.name)…"
        } else {
            config = ModelConfiguration(id: model.repoId)
            loadingStatusText = "Downloading \(model.name)…"
        }
        modelConfiguration = config

        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            ) { progress in
                Task { @MainActor in
                    let pct = Int(progress.fractionCompleted * 100)
                    if pct < 100 {
                        self.loadingStatusText = "Downloading \(model.name)… \(pct)%"
                    } else {
                        self.loadingStatusText = "Loading \(model.name) into memory…"
                    }
                    self.loadState = .loading(progress: progress.fractionCompleted)
                }
            }

            modelContainer = container
            loadState = .loaded
            loadingStatusText = ""
        } catch {
            let msg = error.localizedDescription
            if msg.contains("Unsupported model type") {
                loadState = .error("Unsupported architecture — try a different model")
            } else {
                loadState = .error("Failed: \(msg)")
            }
            loadingStatusText = ""
            modelConfiguration = nil
            throw error
        }
    }

    func unloadModel() {
        modelContainer = nil
        modelConfiguration = nil
        Memory.clearCache()
        loadState = .unloaded
    }

    // MARK: - Delete

    func deleteModel(_ model: MLXModelInfo) {
        if selectedModel?.repoId == model.repoId {
            unloadModel()
            selectedModel = nil
            UserDefaults.standard.removeObject(forKey: Self.selectedModelKey)
        }

        if model.source != .lmStudio && model.localPath == nil {
            try? FileManager.default.removeItem(at: Self.modelCacheDir(for: model.repoId))
        }
        scanForModels()
    }

    // MARK: - Cleanup

    /// Remove empty/incomplete model directories from HF cache and LM Studio.
    /// Returns count of directories removed and bytes freed.
    func cleanupFailedDownloads() -> (removed: Int, bytesFreed: UInt64) {
        var removed = 0
        var bytesFreed: UInt64 = 0

        // Clean HF cache: remove model dirs with no snapshots or empty snapshots
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.hfCacheURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for dir in contents where dir.lastPathComponent.hasPrefix("models--") {
                let snapshots = dir.appendingPathComponent("snapshots")
                let hasConfig = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path))?
                    .contains { name in
                        let snapshotDir = snapshots.appendingPathComponent(name)
                        return FileManager.default.fileExists(
                            atPath: snapshotDir.appendingPathComponent("config.json").path
                        )
                    } ?? false

                if !hasConfig {
                    let size = directorySize(at: dir)
                    try? FileManager.default.removeItem(at: dir)
                    bytesFreed += size
                    removed += 1
                }
            }
        }

        // Clean HF cache tmp directory
        let tmpDir = Self.hfCacheURL.appendingPathComponent("tmp")
        if let tmpContents = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) {
            for file in tmpContents {
                let size = directorySize(at: file)
                try? FileManager.default.removeItem(at: file)
                bytesFreed += size
                removed += 1
            }
        }

        // Clean LM Studio: remove empty model directories (0 bytes, no safetensors)
        if let orgs = try? FileManager.default.contentsOfDirectory(
            at: Self.lmStudioModelsURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for orgDir in orgs {
                guard let modelDirs = try? FileManager.default.contentsOfDirectory(
                    at: orgDir, includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }

                for modelDir in modelDirs {
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isDir),
                          isDir.boolValue else { continue }

                    let files = (try? FileManager.default.contentsOfDirectory(atPath: modelDir.path)) ?? []
                    let hasSafetensors = files.contains { $0.hasSuffix(".safetensors") }
                    let hasGGUF = files.contains { $0.hasSuffix(".gguf") }

                    if !hasSafetensors && !hasGGUF {
                        let size = directorySize(at: modelDir)
                        try? FileManager.default.removeItem(at: modelDir)
                        bytesFreed += size
                        removed += 1
                    }
                }

                // Remove empty org dirs
                if let remaining = try? FileManager.default.contentsOfDirectory(atPath: orgDir.path),
                   remaining.isEmpty {
                    try? FileManager.default.removeItem(at: orgDir)
                }
            }
        }

        if removed > 0 {
            scanForModels()
        }
        return (removed, bytesFreed)
    }

    // MARK: - Helpers

    var systemRAMDescription: String {
        Self.formatBytes(systemRAM)
    }

    func canFitInRAM(_ model: MLXModelInfo) -> Bool {
        model.minimumRAM <= systemRAM
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Private Helpers

    nonisolated private static func modelCacheDir(for repoId: String) -> URL {
        hfCacheURL.appendingPathComponent(
            "models--\(repoId.replacingOccurrences(of: "/", with: "--"))"
        )
    }

    nonisolated private func scanHuggingFaceCache(at url: URL) -> [MLXModelInfo] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var models: [MLXModelInfo] = []
        for dir in contents where dir.lastPathComponent.hasPrefix("models--") {
            let name = dir.lastPathComponent
                .replacingOccurrences(of: "models--", with: "")
                .replacingOccurrences(of: "--", with: "/")

            guard name.lowercased().contains("mlx") else { continue }

            let snapshots = dir.appendingPathComponent("snapshots")
            guard let snapshotDirs = try? FileManager.default.contentsOfDirectory(
                at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            let sorted = snapshotDirs.sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return d1 > d2
            }
            guard let latest = sorted.first else { continue }

            let configFile = latest.appendingPathComponent("config.json")
            guard FileManager.default.fileExists(atPath: configFile.path) else { continue }

            let size = directorySize(at: dir)

            models.append(MLXModelInfo(
                repoId: name,
                name: name.components(separatedBy: "/").last ?? name,
                parameterCount: inferParamCount(from: name),
                quantization: inferQuant(from: name),
                sizeOnDisk: size,
                minimumRAM: size * 2,
                source: .huggingFace
            ))
        }
        return models
    }

    nonisolated private func scanLMStudioModels(at baseURL: URL) -> [MLXModelInfo] {
        guard let orgs = try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var models: [MLXModelInfo] = []
        for orgDir in orgs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: orgDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            let orgName = orgDir.lastPathComponent
            guard let modelDirs = try? FileManager.default.contentsOfDirectory(
                at: orgDir, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for modelDir in modelDirs {
                var isModelDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: modelDir.path, isDirectory: &isModelDir),
                      isModelDir.boolValue else { continue }

                let configFile = modelDir.appendingPathComponent("config.json")
                guard FileManager.default.fileExists(atPath: configFile.path) else { continue }

                guard let files = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path) else { continue }
                let hasSafetensors = files.contains { $0.hasSuffix(".safetensors") }
                guard hasSafetensors else { continue }

                let modelName = modelDir.lastPathComponent
                let repoId = "\(orgName)/\(modelName)"
                let size = directorySize(at: modelDir)

                models.append(MLXModelInfo(
                    repoId: repoId,
                    name: modelName,
                    parameterCount: inferParamCount(from: modelName),
                    quantization: inferQuant(from: modelName),
                    sizeOnDisk: size,
                    minimumRAM: size * 2,
                    source: .lmStudio,
                    localPath: modelDir.path
                ))
            }
        }
        return models
    }

    nonisolated private func inferParamCount(from name: String) -> String {
        let patterns = ["0.5B", "0.8B", "1B", "2B", "3B", "4B", "7B", "8B", "9B", "13B", "14B", "24B", "32B", "70B"]
        let upper = name.uppercased()
        for p in patterns.reversed() {
            if upper.contains(p) || upper.contains("-\(p)") { return p }
        }
        return "?"
    }

    nonisolated private func inferQuant(from name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("4bit") || lower.contains("4-bit") || lower.contains("q4") { return "4-bit" }
        if lower.contains("6bit") || lower.contains("6-bit") || lower.contains("q6") { return "6-bit" }
        if lower.contains("8bit") || lower.contains("8-bit") || lower.contains("q8") { return "8-bit" }
        if lower.contains("bf16") || lower.contains("fp16") { return "fp16" }
        return "?"
    }

    nonisolated private func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

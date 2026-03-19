import Foundation

/// Metadata for a single MLX model (local or remote).
struct MLXModelInfo: Identifiable, Codable, Hashable {
    var id: String { repoId }

    let repoId: String
    let name: String
    let parameterCount: String
    let quantization: String
    let sizeOnDisk: UInt64
    let minimumRAM: UInt64
    let source: ModelSource
    let localPath: String?

    enum ModelSource: String, Codable {
        case huggingFace
        case lmStudio
        case local
        case recommended
    }

    init(repoId: String, name: String, parameterCount: String, quantization: String,
         sizeOnDisk: UInt64, minimumRAM: UInt64,
         source: ModelSource, localPath: String? = nil) {
        self.repoId = repoId
        self.name = name
        self.parameterCount = parameterCount
        self.quantization = quantization
        self.sizeOnDisk = sizeOnDisk
        self.minimumRAM = minimumRAM
        self.source = source
        self.localPath = localPath
    }
}

// MARK: - Recommended Models

extension MLXModelInfo {

    static let recommended: [MLXModelInfo] = [
        // --- 8 GB Macs ---
        // Note: Qwen 3.5 uses "qwen3_5" arch not yet supported by mlx-swift-lm.
        // Stick with qwen2/qwen3/smollm3/gemma3/phi which are supported.
        MLXModelInfo(
            repoId: "mlx-community/SmolLM3-3B-Instruct-4bit",
            name: "SmolLM3 3B (fast, multilingual)",
            parameterCount: "3B",
            quantization: "4-bit",
            sizeOnDisk: 1_700_000_000,
            minimumRAM: 8_000_000_000,
            source: .recommended
        ),
        MLXModelInfo(
            repoId: "mlx-community/gemma-3-4b-it-qat-4bit",
            name: "Gemma 3 4B QAT (Google)",
            parameterCount: "4B",
            quantization: "4-bit",
            sizeOnDisk: 2_500_000_000,
            minimumRAM: 8_000_000_000,
            source: .recommended
        ),
        MLXModelInfo(
            repoId: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            name: "Qwen 2.5 3B Instruct",
            parameterCount: "3B",
            quantization: "4-bit",
            sizeOnDisk: 1_740_000_000,
            minimumRAM: 8_000_000_000,
            source: .recommended
        ),
        MLXModelInfo(
            repoId: "mlx-community/Phi-4-mini-instruct-4bit",
            name: "Phi-4 Mini Instruct",
            parameterCount: "3.8B",
            quantization: "4-bit",
            sizeOnDisk: 2_160_000_000,
            minimumRAM: 8_000_000_000,
            source: .recommended
        ),

        // --- 16 GB Macs ---
        MLXModelInfo(
            repoId: "mlx-community/Qwen3-8B-4bit",
            name: "Qwen 3 8B (best 16GB, reasoning)",
            parameterCount: "8B",
            quantization: "4-bit",
            sizeOnDisk: 4_300_000_000,
            minimumRAM: 16_000_000_000,
            source: .recommended
        ),
        MLXModelInfo(
            repoId: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            name: "Qwen 2.5 7B Instruct",
            parameterCount: "7B",
            quantization: "4-bit",
            sizeOnDisk: 4_280_000_000,
            minimumRAM: 16_000_000_000,
            source: .recommended
        ),
        MLXModelInfo(
            repoId: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            name: "Llama 3.1 8B Instruct",
            parameterCount: "8B",
            quantization: "4-bit",
            sizeOnDisk: 4_520_000_000,
            minimumRAM: 16_000_000_000,
            source: .recommended
        ),

        // --- 32 GB+ Macs ---
        MLXModelInfo(
            repoId: "mlx-community/Mistral-Small-24B-Instruct-2501-4bit",
            name: "Mistral Small 24B",
            parameterCount: "24B",
            quantization: "4-bit",
            sizeOnDisk: 13_300_000_000,
            minimumRAM: 32_000_000_000,
            source: .recommended
        ),
        MLXModelInfo(
            repoId: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit",
            name: "Devstral Small 2 24B (code-focused)",
            parameterCount: "24B",
            quantization: "4-bit",
            sizeOnDisk: 14_100_000_000,
            minimumRAM: 32_000_000_000,
            source: .recommended
        ),
    ]

    /// Returns the best recommended model for the current machine's RAM.
    static var bestForThisMachine: MLXModelInfo {
        let ram = ProcessInfo.processInfo.physicalMemory
        let suitable = recommended.filter { $0.minimumRAM <= ram }
        return suitable.last ?? recommended[0]
    }
}

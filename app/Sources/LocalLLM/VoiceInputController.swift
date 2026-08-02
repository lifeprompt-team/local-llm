import AVFoundation
import Foundation
import Speech

/// AskWindowControllerがOS世代を意識せず音声入力を扱うための最小インターフェース。
@MainActor
protocol VoiceInputControlling: AnyObject {
    var isRecording: Bool { get }
    var onTranscript: ((String) -> Void)? { get set }

    func start() async throws
    func stop() async throws -> String
    func cancel()
}

/// macOS 26のSpeechAnalyzerでマイク音声をオンデバイス転写する。
@available(macOS 26.0, *)
@MainActor
final class VoiceInputController: VoiceInputControlling {
    var onTranscript: ((String) -> Void)?
    private(set) var isRecording = false

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var conversionTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<SendableAudioBuffer>.Continuation?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var conversionErrors: LockedAudioConversionError?
    private var tapInstalled = false
    private var finalizedText = ""
    private var volatileText = ""
    private var resultsError: Error?

    func start() async throws {
        guard !isRecording else { return }
        try await requestMicrophoneAccess()
        try Task.checkCancellation()

        guard let locale = await preferredLocale() else {
            throw VoiceInputError.unsupportedLocale
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        let modules: [any SpeechModule] = [transcriber]

        if let installation = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()

        let inputNode = audioEngine.inputNode
        let naturalFormat = inputNode.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
            throw VoiceInputError.microphoneUnavailable
        }
        guard
            let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: naturalFormat
            )
        else {
            throw VoiceInputError.audioFormatUnavailable
        }
        guard let converter = AudioBufferConverter(from: naturalFormat, to: analysisFormat) else {
            throw VoiceInputError.audioFormatUnavailable
        }

        finalizedText = ""
        volatileText = ""
        resultsError = nil

        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: analysisFormat)
        let (audioStream, audioContinuation) = AsyncStream<SendableAudioBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        let (analyzerStream, analyzerContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.audioContinuation = audioContinuation
        self.inputContinuation = analyzerContinuation

        let conversionErrors = LockedAudioConversionError()
        self.conversionErrors = conversionErrors
        conversionTask = Task.detached(priority: .userInitiated) {
            for await audioBuffer in audioStream {
                guard !Task.isCancelled else { break }
                do {
                    let converted = try converter.convert(audioBuffer.value)
                    if converted.frameLength > 0 {
                        analyzerContinuation.yield(AnalyzerInput(buffer: converted))
                    }
                } catch {
                    conversionErrors.store(error)
                    break
                }
            }
            analyzerContinuation.finish()
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled else { return }
                    self?.receive(String(result.text.characters), isFinal: result.isFinal)
                }
            } catch is CancellationError {
                // パレットを閉じた場合の通常終了。
            } catch {
                self?.resultsError = error
            }
        }

        do {
            try await analyzer.start(inputSequence: analyzerStream)
            try Task.checkCancellation()

            inputNode.installTap(
                onBus: 0,
                bufferSize: 2_048,
                format: naturalFormat
            ) { buffer, _ in
                audioContinuation.yield(SendableAudioBuffer(buffer))
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            cleanupAudioInput()
            audioContinuation.finish()
            conversionTask?.cancel()
            conversionTask = nil
            _ = conversionErrors.take()
            self.conversionErrors = nil
            analyzerContinuation.finish()
            resultsTask?.cancel()
            resultsTask = nil
            self.analyzer = nil
            throw error
        }
    }

    func stop() async throws -> String {
        guard let analyzer else { return combinedText }

        cleanupAudioInput()
        audioContinuation?.finish()
        audioContinuation = nil
        await conversionTask?.value
        conversionTask = nil
        let conversionError = conversionErrors?.take()
        conversionErrors = nil
        inputContinuation?.finish()
        inputContinuation = nil
        isRecording = false

        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultsTask?.value
            resultsTask = nil
            self.analyzer = nil
        } catch {
            resultsTask?.cancel()
            resultsTask = nil
            await analyzer.cancelAndFinishNow()
            self.analyzer = nil
            throw error
        }

        if let resultsError {
            self.resultsError = nil
            throw resultsError
        }
        if let conversionError { throw conversionError }
        return combinedText
    }

    func cancel() {
        cleanupAudioInput()
        audioContinuation?.finish()
        audioContinuation = nil
        conversionTask?.cancel()
        conversionTask = nil
        _ = conversionErrors?.take()
        conversionErrors = nil
        inputContinuation?.finish()
        inputContinuation = nil
        isRecording = false
        resultsTask?.cancel()
        resultsTask = nil

        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        self.analyzer = nil
        finalizedText = ""
        volatileText = ""
    }

    private func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            finalizedText = appendSegment(text, to: finalizedText)
            volatileText = ""
        } else {
            volatileText = text
        }
        onTranscript?(combinedText)
    }

    private var combinedText: String {
        appendSegment(volatileText, to: finalizedText)
    }

    private func appendSegment(_ segment: String, to base: String) -> String {
        guard !segment.isEmpty else { return base }
        guard !base.isEmpty else { return segment }
        guard let last = base.last, let first = segment.first else { return base + segment }
        let needsSpace = last.isASCII && last.isLetter && first.isASCII && first.isLetter
        return base + (needsSpace ? " " : "") + segment
    }

    private func cleanupAudioInput() {
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if audioEngine.isRunning { audioEngine.stop() }
    }

    private func preferredLocale() async -> Locale? {
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
            return locale
        }
        for identifier in ["ja-JP", "en-US"] {
            if let locale = await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)
            ) {
                return locale
            }
        }
        return nil
    }

    private func requestMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw VoiceInputError.microphoneDenied
            }
        case .denied, .restricted:
            throw VoiceInputError.microphoneDenied
        @unknown default:
            throw VoiceInputError.microphoneDenied
        }
    }
}

enum VoiceInputError: LocalizedError {
    case microphoneDenied
    case microphoneUnavailable
    case unsupportedLocale
    case audioFormatUnavailable
    case audioConversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "マイクを使えません。システム設定でLocalLLMのマイクアクセスを許可してください。"
        case .microphoneUnavailable:
            return "利用可能なマイクが見つかりません。"
        case .unsupportedLocale:
            return "現在の言語はオンデバイス音声認識に対応していません。"
        case .audioFormatUnavailable:
            return "音声認識に対応するマイク形式を使えません。"
        case .audioConversionFailed(let detail):
            return "マイク音声を変換できません: \(detail)"
        }
    }
}

@available(macOS 26.0, *)
private final class AudioBufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw VoiceInputError.audioFormatUnavailable
        }

        let inputProvider = ConverterInputProvider(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputProvider.next(status: inputStatus)
        }

        if status == .error {
            throw VoiceInputError.audioConversionFailed(
                conversionError?.localizedDescription ?? "unknown error"
            )
        }
        return output
    }
}

@available(macOS 26.0, *)
private struct SendableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer

    init(_ value: AVAudioPCMBuffer) {
        self.value = value
    }
}

@available(macOS 26.0, *)
private final class ConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let input: AVAudioPCMBuffer
    private var supplied = false

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return input
    }
}

@available(macOS 26.0, *)
private final class LockedAudioConversionError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func store(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func take() -> Error? {
        lock.lock()
        let result = error
        error = nil
        lock.unlock()
        return result
    }
}

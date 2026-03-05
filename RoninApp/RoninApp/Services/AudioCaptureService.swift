import AVFoundation
import CoreMedia
import Foundation
import os.log

private let logger = Logger(subsystem: "com.ronin.app", category: "AudioCapture")

/// Captures microphone audio using AVCaptureSession instead of AVAudioEngine.
///
/// AVAudioEngine auto-creates a hidden aggregate audio device that conflicts
/// with call apps (WhatsApp, Teams, Zoom) which create their own aggregate
/// devices. AVCaptureSession opens the mic directly through Core Audio's
/// multiclient HAL — no aggregate device, no conflicts.
class AudioCaptureService: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "com.ronin.audiocapture")
    private let bufferQueue = DispatchQueue(label: "com.ronin.audiobuffer")

    private var isCapturing = false
    private var isMuted = false
    private var accumulatedBuffer = Data()
    private var callbackCount = 0

    // Lazy resampler — created/recreated when input format changes
    private var converter: AVAudioConverter?
    private var lastSourceSampleRate: Double = 0
    private var lastSourceChannels: UInt32 = 0
    private let targetFormat: AVAudioFormat

    var onAudioChunk: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    private let targetSampleRate: Double = 16000
    private let samplesPerChunk: Int = 32000 // 2 seconds at 16kHz

    override init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        super.init()
    }

    // MARK: - Permission & Start

    func requestPermissionAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.info("Mic permission status: \(String(describing: status.rawValue))")

        switch status {
        case .authorized:
            logger.info("Mic authorized — starting capture")
            startCapture()
        case .notDetermined:
            logger.info("Mic permission not determined — requesting")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                logger.info("Mic permission result: \(granted)")
                if granted {
                    DispatchQueue.main.async { self?.startCapture() }
                } else {
                    self?.onError?("Microphone access denied. Open System Settings > Privacy > Microphone to grant access.")
                }
            }
        case .denied, .restricted:
            logger.error("Mic permission denied/restricted")
            onError?("Microphone access denied. Open System Settings > Privacy > Microphone to grant access.")
        @unknown default:
            onError?("Unable to determine microphone permission status.")
        }
    }

    // MARK: - AVCaptureSession Setup

    private func startCapture() {
        let session = AVCaptureSession()

        // Find the default audio input device
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            logger.error("No audio capture device found")
            onError?("No microphone found. Check your audio input settings.")
            return
        }

        logger.info("Using audio device: \(audioDevice.localizedName) (uid: \(audioDevice.uniqueID))")

        // Create input from the device
        let audioInput: AVCaptureDeviceInput
        do {
            audioInput = try AVCaptureDeviceInput(device: audioDevice)
        } catch {
            logger.error("Failed to create audio input: \(error.localizedDescription)")
            onError?("Failed to open microphone: \(error.localizedDescription)")
            return
        }

        guard session.canAddInput(audioInput) else {
            logger.error("Cannot add audio input to session")
            onError?("Cannot access microphone. It may be in use by another app in a way that prevents sharing.")
            return
        }
        session.addInput(audioInput)

        // Create audio data output
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            logger.error("Cannot add audio output to session")
            onError?("Failed to configure audio capture pipeline.")
            return
        }
        session.addOutput(output)

        // Log the audio connection
        if let connection = output.connection(with: .audio) {
            logger.info("Audio connection active: \(connection.isActive), channels: \(connection.audioChannels.count)")
        }

        // Observe session errors
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionRuntimeError),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionStarted),
            name: .AVCaptureSessionDidStartRunning,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionStopped),
            name: .AVCaptureSessionDidStopRunning,
            object: session
        )

        // Start on a background queue — startRunning() blocks
        captureQueue.async {
            session.startRunning()
        }

        captureSession = session
        audioOutput = output
        isCapturing = true
        callbackCount = 0

        logger.info("AVCaptureSession configured and starting")
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isMuted else { return }

        callbackCount += 1

        // Get the audio format from the sample buffer
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            if callbackCount <= 3 {
                logger.error("No format description in sample buffer")
            }
            return
        }

        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        guard let sourceASBD = asbd?.pointee else {
            if callbackCount <= 3 {
                logger.error("Could not get ASBD from format description")
            }
            return
        }

        let sourceSampleRate = sourceASBD.mSampleRate
        let sourceChannels = sourceASBD.mChannelsPerFrame

        // Extract raw audio samples from CMSampleBuffer
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let rawPtr = dataPointer else { return }

        // Build source AVAudioFormat from the ASBD.
        // Strategy:
        //  1. Try streamDescription (handles most formats)
        //  2. For 3+ channels, add a channel layout (required by AVAudioFormat)
        //  3. Fallback: force mono float32 at the source sample rate
        var mutableASBD = sourceASBD
        let sourceFormat: AVAudioFormat

        if let fmt = AVAudioFormat(streamDescription: &mutableASBD) {
            sourceFormat = fmt
        } else if sourceChannels > 2 {
            // AVAudioFormat needs a channel layout for >2 channels
            var layoutASBD = sourceASBD
            if let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(sourceChannels)),
               let fmt = AVAudioFormat(streamDescription: &layoutASBD, channelLayout: layout) {
                sourceFormat = fmt
                if callbackCount <= 3 {
                    logger.info("Using discrete channel layout for \(sourceChannels)ch audio")
                }
            } else {
                // Last resort: reinterpret as mono (take only channel 0 data)
                // This loses multichannel info but avoids dropping audio entirely
                if let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: sourceSampleRate,
                                           channels: 1, interleaved: false) {
                    sourceFormat = fmt
                    if callbackCount <= 3 {
                        logger.warning("Falling back to mono for \(sourceChannels)ch audio")
                    }
                } else {
                    if callbackCount <= 3 {
                        logger.error("Cannot create any AVAudioFormat for \(sourceSampleRate)Hz/\(sourceChannels)ch")
                    }
                    return
                }
            }
        } else {
            if callbackCount <= 3 {
                logger.error("Cannot create AVAudioFormat from ASBD: \(sourceSampleRate)Hz, \(sourceChannels)ch, flags=\(sourceASBD.mFormatFlags)")
            }
            return
        }

        // Create PCM buffer and copy data
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy raw bytes into the PCM buffer.
        // The ASBD's mBytesPerFrame accounts for all channels and the sample format,
        // so we use it to compute the correct byte count regardless of format.
        let bytesToCopy = min(totalLength, Int(pcmBuffer.frameCapacity) * Int(sourceASBD.mBytesPerFrame))
        if let bufferData = pcmBuffer.floatChannelData {
            memcpy(bufferData[0], rawPtr, bytesToCopy)
        } else if let bufferData = pcmBuffer.int16ChannelData {
            memcpy(bufferData[0], rawPtr, bytesToCopy)
        }

        // Recreate converter if source format changed
        if sourceSampleRate != lastSourceSampleRate || sourceChannels != lastSourceChannels {
            lastSourceSampleRate = sourceSampleRate
            lastSourceChannels = sourceChannels
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            logger.info("Converter: \(sourceSampleRate)Hz/\(sourceChannels)ch → 16000Hz/1ch")
            if converter == nil {
                logger.error("Failed to create converter from \(sourceSampleRate)Hz/\(sourceChannels)ch")
            }
        }

        guard let converter = self.converter else { return }

        // Convert to target format (16kHz mono float32)
        let ratio = targetSampleRate / sourceSampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
        guard outputFrameCount > 0 else { return }

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount + 1024 // extra headroom
        ) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcmBuffer
        }

        if let error = error {
            if callbackCount <= 3 {
                logger.error("Converter error: \(error.localizedDescription)")
            }
            return
        }

        let convertedFrameCount = Int(convertedBuffer.frameLength)
        guard convertedFrameCount > 0, let floatData = convertedBuffer.floatChannelData?[0] else { return }

        // Audio level for UI
        var sum: Float = 0
        for i in 0..<convertedFrameCount { sum += abs(floatData[i]) }
        let level = sum / Float(convertedFrameCount)
        onAudioLevel?(level)

        if callbackCount <= 3 {
            logger.info("Callback #\(self.callbackCount): \(frameCount) frames @ \(sourceSampleRate)Hz → \(convertedFrameCount) frames, level=\(level)")
        }

        // Convert Float32 to Int16 for the backend
        var int16Data = Data(count: convertedFrameCount * 2)
        int16Data.withUnsafeMutableBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<convertedFrameCount {
                let clamped = max(-1.0, min(1.0, floatData[i]))
                int16Buffer[i] = Int16(clamped * 32767)
            }
        }

        bufferQueue.async { [weak self] in
            guard let self = self else { return }
            self.accumulatedBuffer.append(int16Data)

            let bytesPerChunk = self.samplesPerChunk * 2
            while self.accumulatedBuffer.count >= bytesPerChunk {
                let chunk = self.accumulatedBuffer.prefix(bytesPerChunk)
                self.accumulatedBuffer = Data(self.accumulatedBuffer.dropFirst(bytesPerChunk))
                self.onAudioChunk?(Data(chunk))
            }
        }
    }

    // MARK: - Session Notifications

    @objc private func handleSessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        logger.error("Capture session runtime error: \(error.localizedDescription) (code \(error.errorCode))")

        // Try to restart if the session stopped due to an error
        if let session = captureSession, !session.isRunning {
            logger.info("Attempting to restart capture session after error...")
            captureQueue.async {
                session.startRunning()
            }
        }
    }

    @objc private func handleSessionStarted(_ notification: Notification) {
        logger.info("Capture session started running")
    }

    @objc private func handleSessionStopped(_ notification: Notification) {
        logger.warning("Capture session stopped running")
        // Auto-restart if we're still supposed to be capturing
        if isCapturing, let session = captureSession {
            logger.info("Auto-restarting capture session...")
            captureQueue.async {
                session.startRunning()
            }
        }
    }

    // MARK: - Controls

    func stopCapture() {
        guard isCapturing else { return }
        logger.info("Stopping capture (callbacks: \(self.callbackCount))")
        isCapturing = false
        NotificationCenter.default.removeObserver(self)
        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil
        converter = nil
        bufferQueue.async { self.accumulatedBuffer = Data() }
    }

    func pause() {
        // AVCaptureSession doesn't have pause — just mute
        isMuted = true
        bufferQueue.async { self.accumulatedBuffer = Data() }
    }

    func resume() {
        isMuted = false
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            bufferQueue.async { self.accumulatedBuffer = Data() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        captureSession?.stopRunning()
    }
}

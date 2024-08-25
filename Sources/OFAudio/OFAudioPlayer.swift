//
//  File.swift
//
//
//  Created by elonfreedom on 2024/8/25.
//

import AVFoundation

enum AudioPlayerRate: Float {
    case half = 0.5
    case normal = 1.0
    case fast = 1.5
    case veryfast = 2
}

enum AudioPlayerNoiseReduction: Float {
    case off = 0
    case low = 0.5
    case medium = 1.0
    case high = 2.0
}

enum AudioPlayerState {
    case idle // 空闲状态
    case loading // 预加载状态
    case ready // 预加载完成，准备播放
    case playing // 播放中
    case paused // 暂停中
    case stopped // 停止状态
    case finished // 播放结束
}

protocol AudioPlayerDelegate: AnyObject {
    func audioPlayer(_ player: AudioPlayer, didUpdatePlaybackTime currentTime: TimeInterval)
    func audioPlayerBeginInterruption(_ player: AudioPlayer)
    func audioPlayerEndInterruption(_ player: AudioPlayer, withFlags flags: Int)
    func audioPlayerDecodeErrorDidOccur(_ player: AudioPlayer, error: Error?)
    // 播放器状态更新
    func audioPlayer(_ player: AudioPlayer, didUpdateState state: AudioPlayerState)
}

public class AudioPlayer: NSObject {

    static var documentsDirectory: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    //    static var floderPath: String = "Audio/"
    static var fileExtension = ".m4a"
    static let shared = AudioPlayer()
    private var audioEngine: AVAudioEngine!
    private var audioPlayerNode: AVAudioPlayerNode!
    private var eqNode: AVAudioUnitEQ!
    private var audioFile: AVAudioFile?
    private var displayLink: CADisplayLink?
    private(set) var playerState: AudioPlayerState = .idle
    private var isPaused: Bool = false

    weak var delegate: AudioPlayerDelegate?
    // 音频时长
    var audioDuration: TimeInterval {
        guard let audioFile = audioFile else { return 0 }
        let sampleRate = audioFile.processingFormat.sampleRate
        let length = audioFile.length
        return Double(length) / sampleRate
    }

    // 播放速度
    var playbackRate: AudioPlayerRate = .normal {
        didSet {
            audioPlayerNode.rate = playbackRate.rawValue
        }
    }
    //降噪级别
    var noiseReductionLevel: AudioPlayerNoiseReduction = .off {
        didSet {
            configureEQ()
        }
    }

    override init() {
        super.init()
        setupAudioEngine()
    }

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        audioPlayerNode = AVAudioPlayerNode()
        eqNode = AVAudioUnitEQ(numberOfBands: 2)

        audioEngine.attach(audioPlayerNode)
        audioEngine.attach(eqNode)

        // 配置 EQ 滤波器
        configureEQ()

        audioEngine.connect(audioPlayerNode, to: eqNode, format: nil)
        audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: nil)

        // 监听音频会话的中断通知
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
    }

    private func configureEQ() {
        // 根据当前的降噪级别配置 EQ 滤波器
        if noiseReductionLevel == .off {
            // 禁用所有滤波器以保持原声
            for band in eqNode.bands {
                band.bypass = true
            }
        } else {
            let gainValue = -24.0 * noiseReductionLevel.rawValue

            // 设置低通滤波器
            let lowCutFilter = eqNode.bands[0]
            lowCutFilter.filterType = .lowPass
            lowCutFilter.frequency = 1000.0 // 调整此值根据需要
            lowCutFilter.gain = gainValue
            lowCutFilter.bypass = false

            // 设置高通滤波器
            let highCutFilter = eqNode.bands[1]
            highCutFilter.filterType = .highPass
            highCutFilter.frequency = 100.0 // 调整此值根据需要
            highCutFilter.gain = gainValue
            highCutFilter.bypass = false
        }
    }

    private func resetAudioEngine() {
        audioEngine.stop()
        audioEngine.reset()

        if audioEngine.attachedNodes.contains(audioPlayerNode) {
            audioEngine.detach(audioPlayerNode)
        }
        if audioEngine.attachedNodes.contains(eqNode) {
            audioEngine.detach(eqNode)
        }
    }

    func preloadAudio(fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            playerState = .idle
            delegate?.audioPlayer(self, didUpdateState: .idle)
            return
        }
        resetAudioEngine()

        playerState = .loading
        delegate?.audioPlayer(self, didUpdateState: .loading)

        DispatchQueue.global(qos: .background).async {
            do {
                self.audioFile = try AVAudioFile(forReading: fileURL)
                DispatchQueue.main.async {
                    self.setupAudioEngine()
                    self.audioEngine.prepare()
                    self.updateState(.ready)
                }
            } catch {
                print("Error preloading audio file: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.updateState(.idle)
                }
            }
        }
    }

    func playAudio() {
        guard playerState == .ready else {
            print("Player is not ready to play.")
            return
        }

        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            audioPlayerNode.scheduleFile(audioFile!, at: nil) {
                DispatchQueue.main.async { [self] in
                    delegate?.audioPlayer(self, didUpdatePlaybackTime: audioDuration)
                    self.updateState(.finished)
                    stopPlaybackTimeUpdates()
                }
            }
            audioPlayerNode.play()
            audioPlayerNode.rate = playbackRate.rawValue
            startPlaybackTimeUpdates()
            updateState(.playing)
        } catch {
            print("Error starting audio playback: \(error.localizedDescription)")
            updateState(.idle)

        }
    }

    func play(fileURL: URL) {
        preloadAudio(fileURL: fileURL)
        playAudio()
    }

    func pauseAudio() {
        if audioPlayerNode.isPlaying {
            audioPlayerNode.pause()
            isPaused = true // 标记为已暂停
            updateState(.paused)
        }
    }

    func resumeAudio() {
        if !audioPlayerNode.isPlaying {
            audioPlayerNode.play()
            isPaused = false // 恢复播放时重置标记
            updateState(.playing)
        }
    }

    func stopAudio() {
        if audioPlayerNode.isPlaying {
            audioPlayerNode.stop()
        }
        audioEngine.stop()
        audioEngine.reset()
        stopPlaybackTimeUpdates()
        updateState(.stopped)
    }

    private func updateState(_ newState: AudioPlayerState) {
        playerState = newState
        delegate?.audioPlayer(self, didUpdateState: newState)
    }

    func seek(to time: TimeInterval) {
        guard let audioFile = audioFile else { return }
        let sampleRate = audioFile.processingFormat.sampleRate
        let framePosition = AVAudioFramePosition(time * sampleRate)
        audioPlayerNode.stop()
        audioPlayerNode.scheduleSegment(audioFile, startingFrame: framePosition, frameCount: AVAudioFrameCount(audioFile.length - framePosition), at: nil)
        audioPlayerNode.play()
    }

    func fastForward(by seconds: TimeInterval = 5) {
        adjustPlaybackTime(by: seconds)
    }

    func reversal(by seconds: TimeInterval = 5) {
        adjustPlaybackTime(by: -seconds)
    }

    private func adjustPlaybackTime(by seconds: TimeInterval) {
        guard let audioFile = audioFile else { return }
        let currentTime = audioPlayerNode.lastRenderTime.flatMap {
            audioPlayerNode.playerTime(forNodeTime: $0)?.sampleTime
        } ?? 0
        let sampleRate = audioFile.processingFormat.sampleRate
        let newTime = TimeInterval(currentTime) / sampleRate + seconds
        seek(to: newTime)
    }

    // MARK: - Playback Time Updates

    private func startPlaybackTimeUpdates() {
        if displayLink == nil {
            displayLink = CADisplayLink(target: self, selector: #selector(updatePlaybackTime))
            displayLink?.preferredFramesPerSecond = 60 // 使用设备的最大帧率
            displayLink?.add(to: .main, forMode: .common)
        }
    }

    private func stopPlaybackTimeUpdates() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func updatePlaybackTime() {
        guard let nodeTime = audioPlayerNode.lastRenderTime,
            let playerTime = audioPlayerNode.playerTime(forNodeTime: nodeTime) else { return }
        let currentTime = max(0, TimeInterval(playerTime.sampleTime) / playerTime.sampleRate)
        print(currentTime, audioDuration)
        // 设置允许的误差范围，例如 0.05 秒
        let tolerance: TimeInterval = 0.05
        if currentTime >= audioDuration - tolerance {
            // 如果当前时间达到或超过总时长，停止更新
            stopPlaybackTimeUpdates()
            delegate?.audioPlayer(self, didUpdatePlaybackTime: audioDuration)
            updateState(.finished)
        } else if !isPaused {
            // 仅在未暂停时更新时间
            delegate?.audioPlayer(self, didUpdatePlaybackTime: currentTime)
        }
    }

    // MARK: - Handling Audio Interruptions

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            delegate?.audioPlayerBeginInterruption(self)
            pauseAudio()
        case .ended:
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                delegate?.audioPlayerEndInterruption(self, withFlags: Int(options.rawValue))
                if options.contains(.shouldResume) {
                    resumeAudio()
                }
            }
            if playerState != .playing {
                stopPlaybackTimeUpdates() // 如果中断则停止更新
            }
        default:
            break
        }
    }
}

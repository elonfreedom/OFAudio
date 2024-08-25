//
//  File.swift
//  
//
//  Created by elonfreedom on 2024/8/25.
//

import Foundation
import AVFAudio
import AVFoundation

public class AudioSampleExtractor {

    private let segmentDuration: TimeInterval

    init(segmentDuration: TimeInterval = 0.1) {
        self.segmentDuration = segmentDuration
    }

    func extractSamples(from fileURL: URL) -> [CGFloat]? {
        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = audioFile.processingFormat
            let sampleRate = format.sampleRate
            let frameCount = AVAudioFramePosition(audioFile.length)

            let framesPerSegment = AVAudioFrameCount(sampleRate * segmentDuration)
            print("Frames per segment: \(framesPerSegment)")

            // 创建缓冲区来存储每块的音频样本
            let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerSegment)

            var samples: [CGFloat] = []
            var startFrame: AVAudioFramePosition = 0

            while startFrame < frameCount {
                let framesToRead = min(framesPerSegment, AVAudioFrameCount(frameCount - startFrame))
                audioBuffer?.frameLength = framesToRead

                try audioFile.read(into: audioBuffer!, frameCount: framesToRead)

                // 访问音频样本
                let channelCount = Int(audioBuffer!.format.channelCount)
                for channel in 0..<channelCount {
                    guard let channelData = audioBuffer!.floatChannelData?[channel] else {
                        continue
                    }
                    // 将样本从 Float 转换为 CGFloat
                    let channelSamples = Array(UnsafeBufferPointer(start: channelData, count: Int(audioBuffer!.frameLength)))
//                    let cgSamples = channelSamples.map { CGFloat($0) }
                    let rmsValue = sqrt(channelSamples.reduce(0) { $0 + $1 * $1 } / Float(channelSamples.count))
                    let minDb: CGFloat = -50.0 // 最小 dB 值
                    let rmsDB = log10(rmsValue)
                    let level = max(0.0, (CGFloat(rmsDB) - minDb) / -minDb) // 规范化到 [0, 1] 范围
                    let sample = level * 20
                    samples.append(sample)
                }
//                print("Read frames: \(framesToRead), start frame: \(startFrame)")


                // 移动到下一块
                startFrame += AVAudioFramePosition(framesToRead)
            }
            print("Total samples extracted: \(samples.count)")

            return samples

        } catch {
            print("Error reading audio file: \(error.localizedDescription)")
            return nil
        }
    }

    func extractSamplesUsingAVAssetReader(from fileURL: URL) -> [CGFloat]? {
        
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            print("File exists at path: \(fileURL.path)")
        } else {
            print("File does not exist at path: \(fileURL.path)")
        }

        let asset = AVAsset(url: fileURL)

        // 获取音频轨道
        guard let assetTrack = asset.tracks(withMediaType: .audio).first else {
            print("没有找到音频轨道")
            return nil
        }

        do {
            // 创建 AVAssetReader
            let assetReader = try AVAssetReader(asset: asset)

            // 输出设置：线性 PCM 格式
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: assetTrack.naturalTimeScale,
                AVNumberOfChannelsKey: 1, // 通道数：1 代表单声道，2 代表立体声
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]

            let assetReaderOutput = AVAssetReaderTrackOutput(track: assetTrack, outputSettings: outputSettings)
            assetReader.add(assetReaderOutput)

            assetReader.startReading()

            var samples: [CGFloat] = []
            var currentSegmentSamples: [Float] = []

            let framesPerSegment = Int(segmentDuration * Double(assetTrack.naturalTimeScale))
            var framesRead: Int = 0

            // 读取样本
            while let sampleBuffer = assetReaderOutput.copyNextSampleBuffer() {
                if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                    let length = CMBlockBufferGetDataLength(blockBuffer)
                    var data = Data(repeating: 0, count: length)
                    // 使用 withUnsafeMutableBytes 来安全地访问 Data 的字节
                    data.withUnsafeMutableBytes { (rawBufferPointer: UnsafeMutableRawBufferPointer) in
                        if let rawPointer = rawBufferPointer.baseAddress {
                            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: rawPointer)
                        }
                    }
                    let sampleCount = length / MemoryLayout<Int16>.size
                    let samplePointer = data.withUnsafeBytes { $0.bindMemory(to: Int16.self).baseAddress! }
                    let sampleArray = Array(UnsafeBufferPointer(start: samplePointer, count: sampleCount))

                    currentSegmentSamples.append(contentsOf: sampleArray.map { Float($0) / Float(Int16.max) })
                    framesRead += sampleCount

                    // 当读取的帧数达到每段的帧数时，计算该段的平均 dB 值
                    if framesRead >= framesPerSegment {
                        let rmsValue = sqrt(currentSegmentSamples.reduce(0) { $0 + $1 * $1 } / Float(currentSegmentSamples.count))
                        let rmsDB = 20 * log10(rmsValue)
                        let minDb: CGFloat = -50.0 // 假设的最小 dB 值
                        let normalizedLevel = max(0.0, (CGFloat(rmsDB) - minDb) / -minDb)
                        samples.append(normalizedLevel * 20)

                        currentSegmentSamples.removeAll()
                        framesRead = 0
                    }
                }
            }

            // 如果最后一段样本不足 framesPerSegment，也计算它的平均 dB
            if !currentSegmentSamples.isEmpty {
                let rmsValue = sqrt(currentSegmentSamples.reduce(0) { $0 + $1 * $1 } / Float(currentSegmentSamples.count))
                let rmsDB = 20 * log10(rmsValue)
                let minDb: CGFloat = -50.0
                let normalizedLevel = max(0.0, (CGFloat(rmsDB) - minDb) / -minDb)
                samples.append(normalizedLevel * 20)
            }

            print("Total samples extracted: \(samples.count)")

            return samples

        } catch {
            print("Error reading audio file using AVAssetReader: \(error.localizedDescription)")
            return nil
        }
    }

    func extractAverageDbSamples(from fileURL: URL) -> [CGFloat]? {
        do {
            // 读取音频文件
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = audioFile.processingFormat
            let sampleRate = format.sampleRate
            let totalFrameCount = AVAudioFramePosition(audioFile.length)

            // 计算每个段的帧数
            let framesPerSegment = AVAudioFrameCount(sampleRate * segmentDuration)
            print("Frames per segment: \(framesPerSegment)")

            // 创建 PCM 缓冲区
            let audioBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerSegment)

            var averageDbSamples: [CGFloat] = []
            var startFrame: AVAudioFramePosition = 0

            while startFrame < totalFrameCount {
                // 计算要读取的帧数
                let framesToRead = min(framesPerSegment, AVAudioFrameCount(totalFrameCount - startFrame))
                audioBuffer?.frameLength = framesToRead

                // 读取音频文件到缓冲区
                try audioFile.read(into: audioBuffer!, frameCount: framesToRead)

                // 处理每个通道的样本数据
                let channelCount = Int(audioBuffer!.format.channelCount)
                var rmsValues: [Float] = []

                for channel in 0..<channelCount {
                    guard let channelData = audioBuffer!.floatChannelData?[channel] else {
                        continue
                    }

                    // 获取样本数据并计算 RMS
                    let channelSamples = Array(UnsafeBufferPointer(start: channelData, count: Int(audioBuffer!.frameLength)))
                    let rmsValue = sqrt(channelSamples.reduce(0) { $0 + $1 * $1 } / Float(channelSamples.count))
                    rmsValues.append(rmsValue)
                }

                // 计算平均 RMS
                let averageRms = rmsValues.reduce(0, +) / Float(rmsValues.count)
                // 转换为 dB
                let averageDb = log10(averageRms)

                // 将 dB 值规范化到 [0, 1] 范围内
                let minDb: CGFloat = -50.0 // 假设的最小 dB 值
                let normalizedLevel = max(0.0, (CGFloat(averageDb) - minDb) / -minDb)
                let sample = normalizedLevel * 20
                // 添加到结果数组
                averageDbSamples.append(sample)

                print("Segment average dB: \(averageDb), Normalized level: \(normalizedLevel)")

                // 移动到下一段
                startFrame += AVAudioFramePosition(framesToRead)
            }

            print("Total average dB samples extracted: \(averageDbSamples.count)")

            return averageDbSamples

        } catch {
            print("Error reading audio file: \(error.localizedDescription)")
            return nil
        }
    }
}


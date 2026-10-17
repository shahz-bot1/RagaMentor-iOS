import Foundation
import AVFoundation

/// Waveform peak computation (PLAN §9): fold a file's samples into a
/// fixed bucket grid (~6000 buckets per song, so long files cost the
/// same to render). The song-level sidecar cache lives in the LoopLab
/// feature (`SongPeaks`); this is the pure file-level computation.
public enum PeaksService {
    public static let bucketCount = 6000

    /// Stream the file in chunks and fold samples into the bucket grid.
    public static func computePeaks(fileURL: URL, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: fileURL),
              file.length > 0 else { return [] }
        let totalFrames = Int(file.length)
        let chunkFrames = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(chunkFrames)) else { return [] }
        var peaks = [Float](repeating: 0, count: buckets)
        var framesRead = 0
        while framesRead < totalFrames {
            do { try file.read(into: buffer) } catch { break }
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            let channelCount = Int(file.processingFormat.channelCount)
            for i in 0..<count {
                var v: Float = 0
                for ch in 0..<channelCount {
                    v = max(v, abs(channels[ch][i]))
                }
                let bucket = min(buckets - 1, (framesRead + i) * buckets / totalFrames)
                if v > peaks[bucket] { peaks[bucket] = v }
            }
            framesRead += count
        }
        return peaks
    }
}

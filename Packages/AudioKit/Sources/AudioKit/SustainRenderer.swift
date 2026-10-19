import AVFoundation
import Foundation

/// Sample-domain rendering of the web StudioAudio note players
/// (playSampled / playSampledSustain / playSynth), so a note can be
/// scheduled as one pre-rendered buffer on AVAudioPlayerNode:
///
/// - the master envelope is the harmonium envelope (attack 0.02 s to
///   0.9, hold, then a release ending at dur + 0.15 whose span is
///   proportional to the note — the NoteBlend fraction of the
///   duration, floored at 0.12 s — and cosine-shaped, v1.5.13);
/// - notes that fit inside the sample play as a single resampled pass;
/// - longer notes chain the sample's sustain section [s0, s1] as
///   overlapping segments joined by equal-power (sin/cos) crossfades,
///   crossfade = min(0.8 s, 20% of the sample) in source seconds —
///   fadeIn² + fadeOut² = 1 at every point, so the sustained level
///   never dips mid-crossfade;
/// - the synth fallback is a triangle wave with its own envelope.
public enum SustainRenderer {
    /// Equal-power crossfade gains at a phase in 0...1.
    public static func crossfadeGains(phase: Double) -> (fadeIn: Double, fadeOut: Double) {
        let angle = phase * .pi / 2
        return (sin(angle), cos(angle))
    }

    static func expRamp(_ t: Double, from a: Double, to b: Double,
                        start: Double, end: Double) -> Double {
        if t <= start { return a }
        if t >= end { return b }
        return a * pow(b / a, (t - start) / (end - start))
    }

    /// The shared harmonium master envelope at time t.
    public static func masterEnvelope(at t: Double, duration: Double) -> Double {
        if t < 0 { return 0 }
        // Dynamic blending (v1.5.13): the release span is
        // proportional to the note — the NoteBlend fraction of
        // the duration, floored at 0.12 s — and cosine-shaped
        // (the equal-power family the sustain crossfades use).
        // The old fixed exponential dive fell silent well before
        // the next swara at slow tempos: the mechanical pause
        // between notes.
        let releaseSpan = min(1.0, max(0.12, NoteBlend.fraction * duration))
        let holdEnd = max(0.02, duration - releaseSpan)
        if t < 0.02 { return expRamp(t, from: 0.0001, to: 0.9, start: 0, end: 0.02) }
        if t < holdEnd { return 0.9 }
        if t < duration + 0.15 {
            let phase = (t - holdEnd) / (duration + 0.15 - holdEnd)
            return 0.0001 + (0.9 - 0.0001) * cos(phase * .pi / 2)
        }
        return 0.0001
    }

    /// Render a sampled note into a buffer of `outputSampleRate` /
    /// `outputChannels` (standard float format). The output format is
    /// a hard contract: AVAudioPlayerNode crashes when a scheduled
    /// buffer's format differs from the node's connection format, so
    /// callers pass the node format they connected with. Output
    /// channels read source channel min(ch, last) — a mono sample
    /// feeds both stereo channels. Output runs duration + 0.2 s (the
    /// web source stop time).
    public static func render(source: AVAudioPCMBuffer, rate: Double,
                              duration: Double,
                              outputSampleRate: Double,
                              outputChannels: Int) -> AVAudioPCMBuffer? {
        let srcRate = source.format.sampleRate
        let srcChannels = Int(source.format.channelCount)
        let srcFrames = Int(source.frameLength)
        guard srcRate > 0, srcFrames > 0, outputSampleRate > 0, outputChannels > 0,
              let srcData = source.floatChannelData,
              let format = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate,
                                         channels: AVAudioChannelCount(outputChannels)),
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(((duration + 0.2) * outputSampleRate).rounded(.up))),
              let outData = out.floatChannelData else { return nil }
        let sr = outputSampleRate
        let channels = outputChannels
        out.frameLength = AVAudioFrameCount(out.frameCapacity)
        let bd = Double(srcFrames) / srcRate // buffer duration (source seconds)

        func sourceSample(channel: Int, sourcePos: Double) -> Double {
            // sourcePos in source seconds; linear interpolation. The
            // channel clamps to the source's last channel (mono
            // samples feed every output channel).
            let ch = min(channel, srcChannels - 1)
            let x = sourcePos * srcRate
            if x < 0 || x >= Double(srcFrames) { return 0 }
            let i0 = Int(x.rounded(.down))
            let frac = x - Double(i0)
            let a = Double(srcData[ch][i0])
            if i0 + 1 >= srcFrames { return a }
            let b = Double(srcData[ch][i0 + 1])
            return a + (b - a) * frac
        }

        let need = (duration + 0.25) * rate
        let singleSource = bd == 0 || need <= bd - 0.05 || bd <= 2.5

        // Segment plan for the chain path: (start, sourceOffset) in
        // output/source seconds.
        var segments: [(start: Double, offset: Double)] = []
        var xfR = 0.0 // crossfade length in output seconds
        var s1 = 0.0
        if !singleSource {
            let xf = min(0.8, bd * 0.2)
            xfR = xf / rate
            let s0 = min(0.5, bd * 0.1)
            s1 = max(s0 + xf + 0.3, bd - 0.5)
            let endNeed = duration + 0.25
            var start = 0.0, offset = 0.0
            for _ in 0..<64 {
                segments.append((start: start, offset: offset))
                let reachEnd = start + (s1 - offset) / rate
                if reachEnd >= endNeed { break }
                start = reachEnd - xfR
                offset = s0
            }
        }

        func signal(at t: Double) -> [Double] {
            var perChannel = [Double](repeating: 0, count: channels)
            if singleSource {
                // Hard-loop fallback for tiny buffers (web parity):
                // loop [0.1, bd-0.1] once the playhead passes loopEnd.
                var pos = t * rate
                if bd > 1, need > bd - 0.05, pos >= bd - 0.1, bd - 0.2 > 0 {
                    let loopStart = 0.1, loopLen = (bd - 0.1) - loopStart
                    pos = loopStart + (pos - loopStart).truncatingRemainder(dividingBy: loopLen)
                }
                if pos <= bd {
                    for ch in 0..<channels { perChannel[ch] = sourceSample(channel: ch, sourcePos: pos) }
                }
                return perChannel
            }
            for (i, seg) in segments.enumerated() {
                let local = t - seg.start
                if local < 0 { continue }
                let isLast = i == segments.count - 1
                if !isLast && local > (segments[i + 1].start - seg.start) + xfR + 0.05 { continue }
                let srcPos = seg.offset + local * rate
                if srcPos > bd { continue }
                var gain = 1.0
                if i > 0 && local < xfR {
                    gain = crossfadeGains(phase: local / xfR).fadeIn
                }
                if !isLast {
                    let nextStart = segments[i + 1].start - seg.start
                    if local >= nextStart {
                        gain *= crossfadeGains(phase: (local - nextStart) / xfR).fadeOut
                    }
                }
                if gain == 0 { continue }
                for ch in 0..<channels {
                    perChannel[ch] += gain * sourceSample(channel: ch, sourcePos: srcPos)
                }
            }
            return perChannel
        }

        for frame in 0..<Int(out.frameLength) {
            let t = Double(frame) / sr
            let env = masterEnvelope(at: t, duration: duration)
            let sig = signal(at: t)
            for ch in 0..<channels {
                outData[ch][frame] = Float(env * sig[ch])
            }
        }
        return out
    }

    /// Convenience: render at the source's own format.
    public static func render(source: AVAudioPCMBuffer, rate: Double,
                              duration: Double) -> AVAudioPCMBuffer? {
        render(source: source, rate: rate, duration: duration,
               outputSampleRate: source.format.sampleRate,
               outputChannels: Int(source.format.channelCount))
    }

    /// The triangle-wave fallback note (web playSynth): output runs
    /// duration + 0.15 s at the requested format (mono synth feeds
    /// every channel).
    public static func renderSynth(frequency: Double, duration: Double,
                                   sampleRate: Double = 44100,
                                   channels: Int = 1) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels)),
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(((duration + 0.15) * sampleRate).rounded(.up))),
              let data = out.floatChannelData else { return nil }
        let frames = Int(out.frameCapacity)
        out.frameLength = AVAudioFrameCount(frames)
        let holdEnd = max(0.03, duration - 0.09)
        for frame in 0..<frames {
            let t = Double(frame) / sampleRate
            let env: Double
            if t < 0.03 { env = expRamp(t, from: 0.0001, to: 0.4, start: 0, end: 0.03) }
            else if t < holdEnd { env = 0.4 }
            else if t < duration + 0.12 { env = expRamp(t, from: 0.4, to: 0.0001, start: holdEnd, end: duration + 0.12) }
            else { env = 0.0001 }
            let x = (frequency * t).truncatingRemainder(dividingBy: 1)
            let tri = x < 0.5 ? (4 * x - 1) : (3 - 4 * x)
            for ch in 0..<channels { data[ch][frame] = Float(env * tri) }
        }
        return out
    }
}

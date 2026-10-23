import AVFoundation

/// Esportazione ProRes 422 HQ (10 bit) con AVAssetReader → correzione → AVAssetWriter, audio PCM.
enum Esportazione {
    final class Stato: @unchecked Sendable {
        let lock = NSLock()
        var finiti = 0
    }

    /// Contenitore per passare reader/writer alle code di AVFoundation (ognuno usato da una sola coda).
    final class Scatola<T>: @unchecked Sendable { let v: T; init(_ v: T) { self.v = v } }

    static func prores(asset: AVAsset, composizione: AVVideoComposition, audioMix: AVAudioMix? = nil, verso url: URL,
                       progresso: @escaping @Sendable (Double) -> Void) async throws {
        let durata = try await asset.load(.duration).seconds
        let tracceV = try await asset.loadTracks(withMediaType: .video)
        let tracceA = try await asset.loadTracks(withMediaType: .audio)
        guard !tracceV.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        let reader = try AVAssetReader(asset: asset)
        let outV = AVAssetReaderVideoCompositionOutput(videoTracks: tracceV, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        ])
        outV.videoComposition = composizione
        outV.alwaysCopiesSampleData = false
        reader.add(outV)

        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        // tutte le tracce audio mescolate, con i volumi e le dissolvenze del montaggio
        var outA: AVAssetReaderAudioMixOutput?
        if !tracceA.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: tracceA, audioSettings: pcm)
            o.audioMix = audioMix
            reader.add(o); outA = o
        }

        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let rs = composizione.renderSize
        let inV = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422HQ, AVVideoWidthKey: Int(rs.width), AVVideoHeightKey: Int(rs.height),
        ])
        inV.expectsMediaDataInRealTime = false
        writer.add(inV)
        var inA: AVAssetWriterInput?
        if outA != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
            i.expectsMediaDataInRealTime = false
            writer.add(i); inA = i
        }

        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let stato = Stato()
        let totale = outA == nil ? 1 : 2
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            func finito() {
                stato.lock.lock(); stato.finiti += 1; let tutti = stato.finiti == totale; stato.lock.unlock()
                if tutti { cont.resume() }
            }
            let sv = Scatola((inV, outV))
            inV.requestMediaDataWhenReady(on: DispatchQueue(label: "colorista.prores.video")) {
                let (inV, outV) = sv.v
                while inV.isReadyForMoreMediaData {
                    guard let sb = outV.copyNextSampleBuffer() else { inV.markAsFinished(); finito(); return }
                    if !inV.append(sb) { inV.markAsFinished(); finito(); return }
                    progresso(min(1, CMSampleBufferGetPresentationTimeStamp(sb).seconds / max(durata, 0.01)))
                }
            }
            if let inA, let outA {
                let sa = Scatola((inA, outA))
                inA.requestMediaDataWhenReady(on: DispatchQueue(label: "colorista.prores.audio")) {
                    let (inA, outA) = sa.v
                    while inA.isReadyForMoreMediaData {
                        guard let sb = outA.copyNextSampleBuffer() else { inA.markAsFinished(); finito(); return }
                        if !inA.append(sb) { inA.markAsFinished(); finito(); return }
                    }
                }
            }
        }

        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? CocoaError(.fileReadUnknown) }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}

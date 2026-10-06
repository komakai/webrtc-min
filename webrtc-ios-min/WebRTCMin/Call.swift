import AVFoundation
import WebRTC

// A call through a stun-room server (host:port): enters the room, sends the
// camera and mic to whoever else is in it and shows their video, until stop().
//
// The user already in the room sends the Offer when the other's Join arrives,
// so each pair has exactly one offerer. All signaling runs on one serial
// queue, in order: the Offer is sent before the candidates its
// setLocalDescription gathers, and addIceCandidate queues behind
// setRemoteDescription.
final class Call: NSObject {
    private let factory: RTCPeerConnectionFactory
    private let server: String
    private let room: Int
    private let localRenderer: RTCVideoRenderer
    private let remoteRenderer: RTCVideoRenderer
    private let onStatus: (String) -> Void
    private let onRemoteVideo: (Bool) -> Void
    private let onEnd: () -> Void

    private let base: String
    private let iceServers: [RTCIceServer]
    private let queue = DispatchQueue(label: "call")

    // Only used on queue.
    private var user: String?
    private var seen = 0
    private var pc: RTCPeerConnection?
    private var remoteTrack: RTCVideoTrack?
    private var closed = false

    private let camera: RTCCameraVideoCapturer
    private let videoSource: RTCVideoSource
    private let videoTrack: RTCVideoTrack
    private let audioTrack: RTCAudioTrack

    init(
        factory: RTCPeerConnectionFactory,
        server: String,
        room: Int,
        localRenderer: RTCVideoRenderer,
        remoteRenderer: RTCVideoRenderer,
        onStatus: @escaping (String) -> Void,
        onRemoteVideo: @escaping (Bool) -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.factory = factory
        self.server = server
        self.room = room
        self.localRenderer = localRenderer
        self.remoteRenderer = remoteRenderer
        self.onStatus = onStatus
        self.onRemoteVideo = onRemoteVideo
        self.onEnd = onEnd
        base = "http://\(server)/rooms/\(room)"
        let host = server.range(of: ":", options: .backwards).map { String(server[..<$0.lowerBound]) } ?? server
        iceServers = [RTCIceServer(urlStrings: ["stun:\(host):3478"])]

        videoSource = factory.videoSource()
        camera = RTCCameraVideoCapturer(delegate: videoSource)
        videoTrack = factory.videoTrack(with: videoSource, trackId: "video")
        audioTrack = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "audio")
        super.init()

        startCamera()
        videoTrack.add(localRenderer)
        onStatus("Entering room \(room)")
        queue.async { self.guarded(self.enter) }
    }

    func stop() {
        queue.async {
            self.close()
            self.onStatus("Left room \(self.room)")
        }
    }

    func setMuted(_ muted: Bool) {
        queue.async {
            if !self.closed { self.audioTrack.isEnabled = !muted }
        }
    }

    // The front camera, in its format closest to 640x480, at up to 30 fps.
    private func startCamera() {
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == .front }) ?? devices.first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) * Int(da.height) - 640 * 480) < abs(Int(db.width) * Int(db.height) - 640 * 480)
        }
        guard let format else { return }
        let maxFps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        camera.startCapture(with: device, format: format, fps: Int(min(maxFps, 30)))
    }

    private func enter() throws {
        let (code, body) = try http("POST", "\(base)/enter")
        switch code {
        case 200: break
        case 409: return end("Room \(room) is full")
        default: return end("Can't enter room \(room): \(code) \(String(decoding: body, as: UTF8.self))")
        }
        let entered = try json(body) as? [String: Any]
        guard let user = entered?["user"] as? String, let messages = entered?["messages"] as? [[String: Any]] else {
            throw CallError.badResponse
        }
        self.user = user
        seen = messages.count
        let present = messages.contains { $0["type"] as? String == "Join" }
        onStatus(present ? "Connecting" : "Waiting for someone to enter room \(room)")
        // A Join here is from the user already in the room, who sends the Offer.
        handle(messages, offer: false)
        schedulePoll()
    }

    // Also the heartbeat that keeps us in the room.
    private func schedulePoll() {
        queue.asyncAfter(deadline: .now() + 1) {
            self.guarded(self.poll)
        }
    }

    private func poll() throws {
        if closed { return }
        let (code, body) = try http("GET", "\(base)/messages?user=\(user ?? "")&seen=\(seen)")
        if code != 200 { return end("Dropped from room \(room) (\(code))") }
        guard let messages = try json(body) as? [[String: Any]] else { throw CallError.badResponse }
        seen += messages.count
        handle(messages, offer: true)
        schedulePoll()
    }

    private func handle(_ messages: [[String: Any]], offer: Bool) {
        for message in messages {
            let data = message["data"] as? [String: Any]
            switch message["type"] as? String {
            case "Join":
                guard offer else { break }
                onStatus("Connecting")
                let pc = newPeerConnection()
                pc.offer(for: constraints()) { sdp, error in
                    guard let sdp else { return self.onStatus("Can't create SDP: \(error.map { "\($0)" } ?? "")") }
                    self.send("Offer", sdp.json)
                    pc.setLocalDescription(sdp, completionHandler: self.check)
                }
            case "Offer":
                guard let sdp = data.flatMap(RTCSessionDescription.init(json:)) else { break }
                let pc = newPeerConnection()
                pc.setRemoteDescription(sdp) { error in
                    if let error { return self.onStatus("Can't set SDP: \(error)") }
                    pc.answer(for: self.constraints()) { sdp, error in
                        guard let sdp else { return self.onStatus("Can't create SDP: \(error.map { "\($0)" } ?? "")") }
                        self.send("Answer", sdp.json)
                        pc.setLocalDescription(sdp, completionHandler: self.check)
                    }
                }
            case "Answer":
                guard let sdp = data.flatMap(RTCSessionDescription.init(json:)) else { break }
                pc?.setRemoteDescription(sdp, completionHandler: check)
            case "Candidate":
                guard let candidate = data.flatMap(RTCIceCandidate.init(json:)) else { break }
                pc?.add(candidate) { _ in }
            case "RemoveCandidate":
                guard let candidate = data.flatMap(RTCIceCandidate.init(json:)) else { break }
                pc?.remove([candidate])
            case "Leave":
                closePeerConnection()
                onStatus("The other user left. Waiting for someone to enter room \(room)")
            default:
                break
            }
        }
    }

    private func newPeerConnection() -> RTCPeerConnection {
        closePeerConnection()
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        let pc = factory.peerConnection(with: config, constraints: constraints(), delegate: self)!
        pc.add(videoTrack, streamIds: ["stream"])
        pc.add(audioTrack, streamIds: ["stream"])
        self.pc = pc
        return pc
    }

    private func closePeerConnection() {
        remoteTrack?.remove(remoteRenderer)
        remoteTrack = nil
        onRemoteVideo(false)
        pc?.close()
        pc = nil
    }

    private func constraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    }

    private func check(_ error: Error?) {
        if let error { onStatus("Can't set SDP: \(error)") }
    }

    private func send(_ type: String, _ data: [String: Any]) {
        queue.async {
            self.guarded {
                if self.closed { return }
                let body = try JSONSerialization.data(withJSONObject: ["type": type, "data": data])
                _ = try self.http("POST", "\(self.base)/messages?user=\(self.user ?? "")", body)
            }
        }
    }

    private func end(_ status: String) {
        close()
        onStatus(status)
    }

    // Leaves the room and releases everything.
    private func close() {
        if closed { return }
        closed = true
        if let user {
            _ = try? http("POST", "\(base)/messages?user=\(user)", Data(#"{"type":"Leave"}"#.utf8))
        }
        closePeerConnection()
        camera.stopCapture()
        videoTrack.remove(localRenderer)
        onEnd()
    }

    // Runs task, ending the call if the server can't be reached.
    private func guarded(_ task: () throws -> Void) {
        do {
            try task()
        } catch CallError.badResponse {
            end("Bad response from \(server)")
        } catch {
            end("Can't reach \(server): \(error.localizedDescription)")
        }
    }

    // A blocking request, as all signaling runs in order on queue.
    private func http(_ method: String, _ url: String, _ body: Data? = nil) throws -> (Int, Data) {
        guard let url = URL(string: url) else { throw CallError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = method
        request.httpBody = body
        var result: Result<(Int, Data), Error> = .failure(CallError.badResponse)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                result = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }

    private func json(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CallError.badResponse
        }
    }

    private enum CallError: Error {
        case badResponse
    }
}

extension Call: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        send("Candidate", candidate.json)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        candidates.forEach { send("RemoveCandidate", $0.json) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        queue.async {
            guard peerConnection === self.pc else { return }
            self.remoteTrack = track
            track.add(self.remoteRenderer)
            self.onRemoteVideo(true)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .connected: onStatus("Connected in room \(room)")
        case .failed: onStatus("Connection failed")
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// The JSON of the browser's RTCSessionDescription and RTCIceCandidate.
private extension RTCSessionDescription {
    var json: [String: Any] { ["type": RTCSessionDescription.string(for: type), "sdp": sdp] }

    convenience init?(json: [String: Any]) {
        guard let type = json["type"] as? String, let sdp = json["sdp"] as? String else { return nil }
        self.init(type: RTCSessionDescription.type(for: type), sdp: sdp)
    }
}

private extension RTCIceCandidate {
    var json: [String: Any] { ["candidate": sdp, "sdpMid": sdpMid ?? "", "sdpMLineIndex": sdpMLineIndex] }

    convenience init?(json: [String: Any]) {
        guard let sdp = json["candidate"] as? String, let index = json["sdpMLineIndex"] as? Int else { return nil }
        self.init(sdp: sdp, sdpMLineIndex: Int32(index), sdpMid: json["sdpMid"] as? String)
    }
}

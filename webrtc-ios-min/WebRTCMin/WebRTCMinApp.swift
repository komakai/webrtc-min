import AVFoundation
import SwiftUI
import WebRTC

@main
struct WebRTCMinApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// The app's state: the PeerConnectionFactory, the two video views and the
// call, if any.
@MainActor
final class Model: ObservableObject {
    @Published var server = UserDefaults.standard.string(forKey: "server") ?? "192.168.11.12:8080" {
        didSet { UserDefaults.standard.set(server, forKey: "server") }
    }
    @Published var status = ""
    @Published var call: Call?
    @Published var muted = false
    @Published var remoteVideo = false

    let localView = RTCMTLVideoView()
    let remoteView = RTCMTLVideoView()
    private let factory: RTCPeerConnectionFactory

    init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
        // Audio plays on the speaker, as in a video call app.
        let audio = RTCAudioSessionConfiguration.webRTC()
        audio.mode = AVAudioSession.Mode.videoChat.rawValue
        audio.categoryOptions = [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        RTCAudioSessionConfiguration.setWebRTC(audio)
        localView.videoContentMode = .scaleAspectFill
        localView.transform = CGAffineTransform(scaleX: -1, y: 1)  // A mirror.
        remoteView.videoContentMode = .scaleAspectFit
    }

    // Asks for the camera and microphone the first time, then enters room.
    func enter(room: Int) async {
        guard await AVCaptureDevice.requestAccess(for: .video),
              await AVCaptureDevice.requestAccess(for: .audio)
        else {
            status = "The camera and microphone permissions are needed (see Settings > WebRTC min)"
            return
        }
        muted = false
        UIApplication.shared.isIdleTimerDisabled = true
        call = Call(
            factory: factory, server: server, room: room,
            localRenderer: localView, remoteRenderer: remoteView,
            onStatus: { status in Task { @MainActor in self.status = status } },
            onRemoteVideo: { shown in Task { @MainActor in self.remoteVideo = shown } },
            onEnd: {
                Task { @MainActor in
                    self.call = nil
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            })
    }

    func toggleMute() {
        muted.toggle()
        call?.setMuted(muted)
    }
}

// Two screens: home, with a button for each room and a settings icon for the
// server, and the call, with the other user's video, ours in a corner, and
// mute and hang-up buttons.
struct ContentView: View {
    @StateObject private var model = Model()
    @State private var settingsOpen = false
    @State private var draft = ""

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.call == nil { home } else { callScreen }
        }
        .alert("Settings", isPresented: $settingsOpen) {
            TextField("stun-room server (host:port)", text: $draft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("OK") { model.server = draft.trimmingCharacters(in: .whitespaces) }
        } message: {
            Text("stun-room server (host:port)")
        }
    }

    private var home: some View {
        ZStack {
            VStack(spacing: 12) {
                ForEach(1...4, id: \.self) { n in
                    Button {
                        Task { await model.enter(room: n) }
                    } label: {
                        Text("Room \(n)").frame(width: 140)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        draft = model.server
                        settingsOpen = true
                    } label: {
                        Image(systemName: "gearshape").font(.title2).foregroundStyle(.white)
                    }
                    .padding()
                }
                Spacer()
                Text(model.status)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
        }
    }

    private var callScreen: some View {
        ZStack {
            VideoView(view: model.remoteView)
                .ignoresSafeArea()
                .opacity(model.remoteVideo ? 1 : 0)
            VStack {
                HStack {
                    Spacer()
                    VideoView(view: model.localView)
                        .frame(width: 96, height: 128)
                        .clipped()
                        .padding(16)
                }
                Spacer()
                Text(model.status)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                HStack(spacing: 48) {
                    Button(action: model.toggleMute) {
                        Image(systemName: model.muted ? "mic.slash.fill" : "mic.fill")
                            .font(.title2)
                            .foregroundStyle(model.muted ? .black : .white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(model.muted ? Color.white : Color(white: 0.3)))
                    }
                    .accessibilityLabel(model.muted ? "Unmute" : "Mute")
                    Button {
                        model.call?.stop()
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color(red: 0.83, green: 0.18, blue: 0.18)))
                    }
                    .accessibilityLabel("Hang up")
                }
                .padding(.top, 24)
                .padding(.bottom, 32)
            }
        }
    }
}

// Shows one of the model's RTCMTLVideoViews, which outlive the screens.
struct VideoView: UIViewRepresentable {
    let view: RTCMTLVideoView

    func makeUIView(context: Context) -> RTCMTLVideoView { view }
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}

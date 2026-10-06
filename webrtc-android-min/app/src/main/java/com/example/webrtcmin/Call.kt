package com.example.webrtcmin

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.webrtc.AddIceObserver
import org.webrtc.Camera2Enumerator
import org.webrtc.DataChannel
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceTextureHelper
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoSink
import org.webrtc.VideoTrack

// A call through a stun-room server (host:port): enters the room, sends the
// camera and mic to whoever else is in it and shows their video, until stop().
//
// The user already in the room sends the Offer when the other's Join arrives,
// so each pair has exactly one offerer. All signaling runs on one thread, in
// order: the Offer is sent before the candidates its setLocalDescription
// gathers, and addIceCandidate queues behind setRemoteDescription.
class Call(
    context: Context,
    private val factory: PeerConnectionFactory,
    eglBase: EglBase,
    private val server: String,
    private val room: Int,
    private val localSink: VideoSink,
    private val remoteRenderer: SurfaceViewRenderer,
    private val onStatus: (String) -> Unit,
    private val onEnd: () -> Unit,
) {
    private val base = "http://$server/rooms/$room"
    private val iceServers = listOf(
        PeerConnection.IceServer.builder("stun:${server.substringBeforeLast(':')}:3478").createIceServer()
    )
    private val executor = Executors.newSingleThreadScheduledExecutor()

    // Only used on executor.
    private var user: String? = null
    private var seen = 0
    private var pc: PeerConnection? = null
    private var closed = false

    private val audioManager = context.getSystemService(AudioManager::class.java)
    private val camera = Camera2Enumerator(context).run {
        createCapturer(deviceNames.firstOrNull { isFrontFacing(it) } ?: deviceNames.first(), null)
    }
    private val textureHelper = SurfaceTextureHelper.create("camera", eglBase.eglBaseContext)
    private val videoSource = factory.createVideoSource(false)
    private val videoTrack = factory.createVideoTrack("video", videoSource)
    private val audioSource = factory.createAudioSource(MediaConstraints())
    private val audioTrack = factory.createAudioTrack("audio", audioSource)

    init {
        camera.initialize(textureHelper, context, videoSource.capturerObserver)
        camera.startCapture(640, 480, 30)
        videoTrack.addSink(localSink)
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        setSpeaker(true)
        onStatus("Entering room $room")
        post { enter() }
    }

    fun stop() = post {
        close()
        onStatus("Left room $room")
    }

    fun setMuted(muted: Boolean) = post {
        if (!closed) audioTrack.setEnabled(!muted)
    }

    private fun enter() {
        val (code, body) = http("POST", "$base/enter")
        when (code) {
            200 -> {}
            409 -> return end("Room $room is full")
            else -> return end("Can't enter room $room: $code $body")
        }
        val entered = JSONObject(body)
        user = entered.getString("user")
        val messages = entered.getJSONArray("messages")
        seen = messages.length()
        val present = (0 until messages.length()).any { messages.getJSONObject(it).getString("type") == "Join" }
        onStatus(if (present) "Connecting" else "Waiting for someone to enter room $room")
        // A Join here is from the user already in the room, who sends the Offer.
        handle(messages, offer = false)
        executor.scheduleWithFixedDelay({ guard(::poll) }, 0, 1, TimeUnit.SECONDS)
    }

    // Also the heartbeat that keeps us in the room.
    private fun poll() {
        if (closed) return
        val (code, body) = http("GET", "$base/messages?user=$user&seen=$seen")
        if (code != 200) return end("Dropped from room $room ($code)")
        val messages = JSONArray(body)
        seen += messages.length()
        handle(messages, offer = true)
    }

    private fun handle(messages: JSONArray, offer: Boolean) {
        for (i in 0 until messages.length()) {
            val message = messages.getJSONObject(i)
            val data = message.optJSONObject("data")
            when (message.getString("type")) {
                "Join" -> if (offer) {
                    onStatus("Connecting")
                    val pc = newPeerConnection()
                    pc.createOffer(object : Sdp() {
                        override fun onCreateSuccess(sdp: SessionDescription) {
                            send("Offer", sdp.toJson())
                            pc.setLocalDescription(Sdp(), sdp)
                        }
                    }, MediaConstraints())
                }
                "Offer" -> {
                    val pc = newPeerConnection()
                    pc.setRemoteDescription(object : Sdp() {
                        override fun onSetSuccess() = pc.createAnswer(object : Sdp() {
                            override fun onCreateSuccess(sdp: SessionDescription) {
                                send("Answer", sdp.toJson())
                                pc.setLocalDescription(Sdp(), sdp)
                            }
                        }, MediaConstraints())
                    }, data!!.toSdp())
                }
                "Answer" -> pc?.setRemoteDescription(Sdp(), data!!.toSdp())
                "Candidate" -> pc?.addIceCandidate(data!!.toCandidate(), object : AddIceObserver {
                    override fun onAddSuccess() {}
                    override fun onAddFailure(error: String) {}
                })
                "RemoveCandidate" -> pc?.removeIceCandidates(arrayOf(data!!.toCandidate()))
                "Leave" -> {
                    closePeerConnection()
                    onStatus("The other user left. Waiting for someone to enter room $room")
                }
            }
        }
    }

    private fun newPeerConnection(): PeerConnection {
        closePeerConnection()
        val pc = factory.createPeerConnection(PeerConnection.RTCConfiguration(iceServers), object : PeerConnection.Observer {
            override fun onIceCandidate(candidate: IceCandidate) = send("Candidate", candidate.toJson())
            override fun onIceCandidatesRemoved(candidates: Array<IceCandidate>) =
                candidates.forEach { send("RemoveCandidate", it.toJson()) }
            override fun onTrack(transceiver: RtpTransceiver) {
                (transceiver.receiver.track() as? VideoTrack)?.addSink(remoteRenderer)
            }
            override fun onConnectionChange(state: PeerConnection.PeerConnectionState) {
                when (state) {
                    PeerConnection.PeerConnectionState.CONNECTED -> onStatus("Connected in room $room")
                    PeerConnection.PeerConnectionState.FAILED -> onStatus("Connection failed")
                    else -> {}
                }
            }
            override fun onSignalingChange(state: PeerConnection.SignalingState) {}
            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {}
            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) {}
            override fun onAddStream(stream: MediaStream) {}
            override fun onRemoveStream(stream: MediaStream) {}
            override fun onDataChannel(channel: DataChannel) {}
            override fun onRenegotiationNeeded() {}
        })!!
        pc.addTrack(videoTrack, listOf("stream"))
        pc.addTrack(audioTrack, listOf("stream"))
        this.pc = pc
        return pc
    }

    private fun closePeerConnection() {
        pc?.dispose()
        pc = null
        remoteRenderer.clearImage()
    }

    private fun send(type: String, data: JSONObject) = post {
        if (!closed) http("POST", "$base/messages?user=$user", JSONObject().put("type", type).put("data", data).toString())
    }

    private fun end(status: String) {
        close()
        onStatus(status)
    }

    // Leaves the room and releases everything.
    private fun close() {
        if (closed) return
        closed = true
        user?.let { runCatching { http("POST", "$base/messages?user=$it", """{"type":"Leave"}""") } }
        closePeerConnection()
        camera.stopCapture()
        camera.dispose()
        videoTrack.removeSink(localSink)
        videoTrack.dispose()
        videoSource.dispose()
        audioTrack.dispose()
        audioSource.dispose()
        textureHelper.dispose()
        setSpeaker(false)
        audioManager.mode = AudioManager.MODE_NORMAL
        executor.shutdown()
        onEnd()
    }

    private fun setSpeaker(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 31) {
            if (on) audioManager.availableCommunicationDevices
                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                ?.let { audioManager.setCommunicationDevice(it) }
            else audioManager.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = on
        }
    }

    // Runs task on executor, ending the call if the server can't be reached.
    private fun post(task: () -> Unit) {
        try {
            executor.execute { guard(task) }
        } catch (_: RejectedExecutionException) {
            // Already closed.
        }
    }

    private fun guard(task: () -> Unit) {
        try {
            task()
        } catch (e: IOException) {
            end("Can't reach $server: ${e.message}")
        } catch (e: JSONException) {
            end("Bad response from $server: ${e.message}")
        }
    }

    private fun http(method: String, url: String, body: String? = null): Pair<Int, String> {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = method
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            if (body != null) {
                connection.doOutput = true
                connection.outputStream.use { it.write(body.toByteArray()) }
            }
            val code = connection.responseCode
            val stream = if (code < 400) connection.inputStream else connection.errorStream
            return code to (stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally {
            connection.disconnect()
        }
    }

    private open inner class Sdp : SdpObserver {
        override fun onCreateSuccess(sdp: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String) = onStatus("Can't create SDP: $error")
        override fun onSetFailure(error: String) = onStatus("Can't set SDP: $error")
    }
}

// The JSON of the browser's RTCSessionDescription and RTCIceCandidate.
private fun SessionDescription.toJson() = JSONObject().put("type", type.canonicalForm()).put("sdp", description)

private fun JSONObject.toSdp() =
    SessionDescription(SessionDescription.Type.fromCanonicalForm(getString("type")), getString("sdp"))

private fun IceCandidate.toJson() =
    JSONObject().put("candidate", sdp).put("sdpMid", sdpMid).put("sdpMLineIndex", sdpMLineIndex)

private fun JSONObject.toCandidate() = IceCandidate(getString("sdpMid"), getInt("sdpMLineIndex"), getString("candidate"))

package org.webrtc.min;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.content.Context;
import androidx.test.core.app.ApplicationProvider;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.webrtc.DataChannel;
import org.webrtc.DefaultVideoDecoderFactory;
import org.webrtc.DefaultVideoEncoderFactory;
import org.webrtc.EglBase;
import org.webrtc.IceCandidate;
import org.webrtc.JavaI420Buffer;
import org.webrtc.MediaStream;
import org.webrtc.MediaStreamTrack;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.RtpTransceiver;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;
import org.webrtc.VideoCodecInfo;
import org.webrtc.VideoFrame;
import org.webrtc.audio.JavaAudioDeviceModule;

/**
 * Loads libjingle_peerconnection_so through the AAR's Java API and connects
 * two PeerConnections over loopback with a data channel (ICE, DTLS, SCTP),
 * plus audio and video transceivers (SRTP negotiation).
 */
@RunWith(AndroidJUnit4.class)
public class WebrtcSmokeTest {
  private static final int TIMEOUT_S = 20;

  private EglBase eglBase;
  private PeerConnectionFactory factory;

  @Before
  public void setUp() {
    Context context = ApplicationProvider.getApplicationContext();
    PeerConnectionFactory.initialize(
        PeerConnectionFactory.InitializationOptions.builder(context)
            .createInitializationOptions());
    eglBase = EglBase.create();
    // Allow loopback networks (ignored by default), so the loopback test
    // doesn't depend on Android's network monitor having reported Wi-Fi or
    // mobile networks before ICE gathering starts.
    PeerConnectionFactory.Options options = new PeerConnectionFactory.Options();
    options.networkIgnoreMask = 0;
    factory =
        PeerConnectionFactory.builder()
            .setOptions(options)
            .setAudioDeviceModule(JavaAudioDeviceModule.builder(context).createAudioDeviceModule())
            .setVideoEncoderFactory(
                new DefaultVideoEncoderFactory(eglBase.getEglBaseContext(), true, true))
            .setVideoDecoderFactory(new DefaultVideoDecoderFactory(eglBase.getEglBaseContext()))
            .createPeerConnectionFactory();
  }

  @After
  public void tearDown() {
    factory.dispose();
    eglBase.release();
  }

  @Test
  public void videoFrameBuffers() {
    JavaI420Buffer buffer = JavaI420Buffer.allocate(64, 48);
    VideoFrame.Buffer scaled = buffer.cropAndScale(0, 0, 64, 48, 32, 24);
    VideoFrame.I420Buffer i420 = scaled.toI420();
    assertEquals(32, i420.getWidth());
    assertEquals(24, i420.getHeight());
    i420.release();
    scaled.release();
    buffer.release();
  }

  @Test
  public void codecFactories() {
    VideoCodecInfo[] encoders =
        new DefaultVideoEncoderFactory(eglBase.getEglBaseContext(), true, true)
            .getSupportedCodecs();
    VideoCodecInfo[] decoders =
        new DefaultVideoDecoderFactory(eglBase.getEglBaseContext()).getSupportedCodecs();
    // Hardware (MediaCodec) codecs only: there are no software video codecs.
    assertTrue("no video encoders", encoders.length > 0);
    assertTrue("no video decoders", decoders.length > 0);
  }

  @Test
  public void loopbackDataChannel() throws Exception {
    Peer caller = new Peer("caller");
    Peer callee = new Peer("callee");

    caller.pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO);
    caller.pc.addTransceiver(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO);
    DataChannel channel = caller.pc.createDataChannel("smoke", new DataChannel.Init());
    CountDownLatch open = new CountDownLatch(1);
    channel.registerObserver(
        new DataChannel.Observer() {
          @Override
          public void onBufferedAmountChange(long previousAmount) {}

          @Override
          public void onStateChange() {
            if (channel.state() == DataChannel.State.OPEN) {
              open.countDown();
            }
          }

          @Override
          public void onMessage(DataChannel.Buffer buffer) {}
        });

    // No trickle ICE: each side sends its description once gathering is
    // complete, with all its candidates in it.
    set(caller.pc, create(caller.pc, true), true);
    SessionDescription offer = caller.gathered();
    assertTrue(offer.description.contains("m=application"));
    assertTrue(offer.description.contains("m=audio"));
    assertTrue(offer.description.contains("m=video"));
    assertTrue(offer.description.contains("a=candidate"));
    set(callee.pc, offer, false);
    set(callee.pc, create(callee.pc, false), true);
    set(caller.pc, callee.gathered(), false);

    assertTrue("data channel didn't open", open.await(TIMEOUT_S, TimeUnit.SECONDS));
    assertTrue(
        "callee didn't get the data channel", callee.dataChannel.await(TIMEOUT_S, TimeUnit.SECONDS));
    channel.send(
        new DataChannel.Buffer(
            ByteBuffer.wrap("hello".getBytes(StandardCharsets.UTF_8)), false));
    assertTrue("no message", callee.message.await(TIMEOUT_S, TimeUnit.SECONDS));
    assertEquals("hello", callee.received.get());

    channel.dispose();
    caller.pc.dispose();
    callee.pc.dispose();
  }

  private static SessionDescription create(PeerConnection pc, boolean offer)
      throws InterruptedException {
    AtomicReference<SessionDescription> result = new AtomicReference<>();
    AtomicReference<String> error = new AtomicReference<>();
    CountDownLatch done = new CountDownLatch(1);
    SdpObserver observer =
        new SdpObserverAdapter() {
          @Override
          public void onCreateSuccess(SessionDescription sdp) {
            result.set(sdp);
            done.countDown();
          }

          @Override
          public void onCreateFailure(String e) {
            error.set(e);
            done.countDown();
          }
        };
    if (offer) {
      pc.createOffer(observer, new org.webrtc.MediaConstraints());
    } else {
      pc.createAnswer(observer, new org.webrtc.MediaConstraints());
    }
    assertTrue(done.await(TIMEOUT_S, TimeUnit.SECONDS));
    assertNotNull("create failed: " + error.get(), result.get());
    return result.get();
  }

  private static void set(PeerConnection pc, SessionDescription sdp, boolean local)
      throws InterruptedException {
    AtomicReference<String> error = new AtomicReference<>();
    CountDownLatch done = new CountDownLatch(1);
    SdpObserver observer =
        new SdpObserverAdapter() {
          @Override
          public void onSetSuccess() {
            done.countDown();
          }

          @Override
          public void onSetFailure(String e) {
            error.set(e);
            done.countDown();
          }
        };
    if (local) {
      pc.setLocalDescription(observer, sdp);
    } else {
      pc.setRemoteDescription(observer, sdp);
    }
    assertTrue(done.await(TIMEOUT_S, TimeUnit.SECONDS));
    assertEquals(null, error.get());
  }

  private class Peer implements PeerConnection.Observer {
    final PeerConnection pc;
    final CountDownLatch gatheringComplete = new CountDownLatch(1);
    final CountDownLatch dataChannel = new CountDownLatch(1);
    final CountDownLatch message = new CountDownLatch(1);
    final AtomicReference<String> received = new AtomicReference<>();

    Peer(String name) {
      List<PeerConnection.IceServer> noServers = new ArrayList<>();
      pc = factory.createPeerConnection(new PeerConnection.RTCConfiguration(noServers), this);
      assertNotNull(name + ": createPeerConnection failed", pc);
    }

    SessionDescription gathered() throws InterruptedException {
      assertTrue(
          "ICE gathering didn't complete", gatheringComplete.await(TIMEOUT_S, TimeUnit.SECONDS));
      return pc.getLocalDescription();
    }

    @Override
    public void onIceGatheringChange(PeerConnection.IceGatheringState newState) {
      if (newState == PeerConnection.IceGatheringState.COMPLETE) {
        gatheringComplete.countDown();
      }
    }

    @Override
    public void onIceCandidate(IceCandidate candidate) {}

    @Override
    public void onDataChannel(DataChannel channel) {
      channel.registerObserver(
          new DataChannel.Observer() {
            @Override
            public void onBufferedAmountChange(long previousAmount) {}

            @Override
            public void onStateChange() {}

            @Override
            public void onMessage(DataChannel.Buffer buffer) {
              byte[] bytes = new byte[buffer.data.remaining()];
              buffer.data.get(bytes);
              received.set(new String(bytes, StandardCharsets.UTF_8));
              message.countDown();
            }
          });
      dataChannel.countDown();
    }

    @Override
    public void onSignalingChange(PeerConnection.SignalingState newState) {}

    @Override
    public void onIceConnectionChange(PeerConnection.IceConnectionState newState) {}

    @Override
    public void onIceConnectionReceivingChange(boolean receiving) {}

    @Override
    public void onIceCandidatesRemoved(IceCandidate[] candidates) {}

    @Override
    public void onAddStream(MediaStream stream) {}

    @Override
    public void onRemoveStream(MediaStream stream) {}

    @Override
    public void onRenegotiationNeeded() {}

    @Override
    public void onTrack(RtpTransceiver transceiver) {}
  }

  private abstract static class SdpObserverAdapter implements SdpObserver {
    @Override
    public void onCreateSuccess(SessionDescription sdp) {}

    @Override
    public void onSetSuccess() {}

    @Override
    public void onCreateFailure(String error) {}

    @Override
    public void onSetFailure(String error) {}
  }
}

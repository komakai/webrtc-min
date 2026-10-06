# stun-room

A STUN server and a room server for testing WebRTC on a LAN, in one Kotlin
file with Ktor. The STUN server answers Binding requests over UDP with the
sender's address in an XOR-MAPPED-ADDRESS (RFC 8489), and nothing else. The
room server has rooms 1 to 4, each for up to two users who exchange messages
(SDP, ICE candidates and so on) through it. `../webrtc-android-min` is a client.

```sh
./gradlew run                       # HTTP on 8080, STUN on UDP 3478
./gradlew run --args="9000 19302"   # other ports
./gradlew installDist               # or build build/install/stun-room/bin/stun-room
```

Requirements: JDK 17+ (Gradle comes with the wrapper). It runs on Linux and
macOS, and on Windows under WSL2. Under WSL2's default NAT networking, other
machines can't reach it: use mirrored networking (`networkingMode=mirrored`
under `[wsl2]` in `%UserProfile%\.wslconfig`, then `wsl --shutdown`), and allow
the ports in through the Hyper-V firewall, from an administrator PowerShell:

```powershell
foreach ($r in @(@{P="TCP"; L=8080}, @{P="UDP"; L=3478})) {
  New-NetFirewallHyperVRule -Name "stun-room-$($r.P)" -DisplayName "stun-room $($r.P)" -Direction Inbound `
    -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol $r.P -LocalPorts $r.L
}
```

## API

Plain HTTP, so `curl` works as a client. `{n}` is the room, 1 to 4, and `{id}`
is the user's id.

| Request | Response |
|---|---|
| `POST /rooms/{n}/enter` | `{"user": id, "messages": [...]}`: the new user's id and the other user's messages so far, or 409 if the room already has two users |
| `POST /rooms/{n}/messages?user={id}` | Empty; the body is a message for the other user |
| `GET /rooms/{n}/messages?user={id}&seen={count}` | A JSON array of the other user's messages after the first `count` (default 0) |

A message is JSON, `{"type": ..., "data": ...}`. `type` is one of `Join`,
`Candidate`, `RemoveCandidate`, `Offer`, `Answer`, `Heartbeat` and `Leave`, and
the optional `data` is any JSON, passed on as is: e.g. an `RTCIceCandidate`'s
or `RTCSessionDescription`'s `toJSON()`.

Each room has two places, each with a list of the messages from the users in
it, and a user only gets the other place's list. The server adds messages
itself:

- `Join` when a user enters.
- `Heartbeat` each time a user GETs messages.
- `Leave` when a user leaves, by POSTing `Leave` or by timing out. The messages
  the other user had sent are dropped, since they were for the user who left.

A place's list goes on when a new user takes the place, so the user who stayed
sees `Leave` and then the new user's `Join`. When the last user leaves, both
lists are emptied.

A client keeps `count` as the number of messages it has received, starting with
those `enter` returned, and passes it as `seen` to get only new ones.

A request for a user who isn't in the room returns 404, as does an unknown room;
a message that isn't valid JSON or has an unknown type returns 400. A user who
makes no request for 30 seconds is taken out of the room, so clients should
poll `messages` every few seconds, and enter again on a 404.

```sh
u=localhost:8080/rooms/1
curl -XPOST $u/enter                # {"user":"<A>","messages":[]}
curl -XPOST "$u/messages?user=<A>" -d '{"type":"Offer","data":{"type":"offer","sdp":"v=0..."}}'
curl -XPOST $u/enter                # {"user":"<B>","messages":[{"type":"Join"},{"type":"Offer",...}]}
curl "$u/messages?user=<B>&seen=2"  # A's messages since
```

## stun-room API

| Request | Response |
|---|---|
| `POST /rooms/{n}/enter` | `{"user": id, "messages": [...]}`: the new user's id and the other user's messages so far, or 409 if the room already has two users |
| `POST /rooms/{n}/messages?user={id}` | Empty; the body is a message for the other user |
| `GET /rooms/{n}/messages?user={id}&seen={count}` | A JSON array of the other user's messages after the first `count` (default 0) |

Messages are JSON objects of the form:
```json
{
    "type": ...,
    "data": ...
}
```
Valid values for the `type` field are `Join`, `Candidate`, `RemoveCandidate`, `Offer`, `Answer`, `Heartbeat` and `Leave`.

The optional `data` field is a JSON object, passed through as is e.g. an `RTCIceCandidate`'s
or `RTCSessionDescription`'s `toJSON()`.

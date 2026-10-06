// A STUN server and a room server for testing WebRTC on a LAN. Rooms 1 to 4
// each hold up to two users, who send each other messages through the HTTP API
// (see README.md). STUN answers Binding requests over UDP.
//
//   ./gradlew run --args="[http port] [stun port]"   # defaults 8080 and 3478
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.ApplicationCall
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.util.UUID
import kotlin.concurrent.thread
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull

// Users that make no request for this long are taken out of their room. Times
// are from System.nanoTime(), which wall-clock adjustments don't move.
const val TIMEOUT_NS = 30_000_000_000

@Serializable
enum class Type { Join, Candidate, RemoveCandidate, Offer, Answer, Heartbeat, Leave }

// data is passed on as is: e.g. an RTCIceCandidate or RTCSessionDescription's
// toJSON().
@Serializable
class Message(val type: Type, val data: JsonElement = JsonNull)

// The response to enter: the new user's id and the other user's messages so far.
@Serializable
class Entered(val user: String, val messages: List<Message>)

class User(val id: String, val place: Int) {
    var lastRequest = System.nanoTime()
}

// A room's two places, and for each the messages from the users in it, in order.
// A place's list goes on when a new user takes it, so the other user's count of
// it stays right.
class Room {
    val users = arrayOfNulls<User>(2)
    val messages = List(2) { mutableListOf<Message>() }

    // Sends Leave to the other user, whose messages so far were for this one
    // and are dropped. If no one is left, both lists are emptied.
    fun leave(user: User) {
        val other = 1 - user.place
        users[user.place] = null
        messages[other].clear()
        if (users[other] == null) messages[user.place].clear() else messages[user.place] += Message(Type.Leave)
    }

    fun expire() {
        val now = System.nanoTime()
        users.filterNotNull().filter { now - it.lastRequest > TIMEOUT_NS }.forEach { leave(it) }
    }
}

// Rooms 1 to 4. Guarded by synchronized(rooms).
val rooms = List(4) { Room() }

fun main(args: Array<String>) {
    val httpPort = args.getOrNull(0)?.toInt() ?: 8080
    val stunPort = args.getOrNull(1)?.toInt() ?: 3478
    thread(isDaemon = true) { stun(stunPort) }
    println("stun-room: HTTP on TCP port $httpPort, STUN on UDP port $stunPort")

    embeddedServer(CIO, port = httpPort) {
        routing {
            route("/rooms/{room}") {
                post("enter") {
                    val room = call.room() ?: return@post call.respondText("no such room\n", status = HttpStatusCode.NotFound)
                    val entered = synchronized(rooms) {
                        room.expire()
                        val place = room.users.indexOf(null)
                        if (place < 0) return@synchronized null
                        val user = User(UUID.randomUUID().toString(), place)
                        room.users[place] = user
                        room.messages[place] += Message(Type.Join)
                        Json.encodeToString(Entered(user.id, room.messages[1 - place].toList()))
                    }
                    if (entered == null) call.respondText("room is full\n", status = HttpStatusCode.Conflict)
                    else call.respondText(entered)
                }
                // Sends the message to the other user. Leave also takes the
                // sender out of the room.
                post("messages") {
                    val message = try {
                        Json.decodeFromString<Message>(call.receiveText())
                    } catch (e: IllegalArgumentException) {
                        return@post call.respondText("bad message: ${e.message}\n", status = HttpStatusCode.BadRequest)
                    }
                    call.withUser { room, user ->
                        if (message.type == Type.Leave) room.leave(user) else room.messages[user.place] += message
                        ""
                    }
                }
                // Sends a Heartbeat to the other user, then returns the other
                // user's messages after the first ?seen= (default 0).
                get("messages") {
                    val seen = call.request.queryParameters["seen"]?.toIntOrNull() ?: 0
                    call.withUser { room, user ->
                        room.messages[user.place] += Message(Type.Heartbeat)
                        Json.encodeToString(room.messages[1 - user.place].drop(seen))
                    }
                }
            }
        }
    }.start(wait = true)
}

fun ApplicationCall.room() = parameters["room"]?.toIntOrNull()?.takeIf { it in 1..4 }?.let { rooms[it - 1] }

// Finds the user named by ?user= in the room, counts the request as a
// heartbeat and responds with block's result, or 404 if they aren't there.
suspend fun ApplicationCall.withUser(block: (Room, User) -> String) {
    val room = room()
    val id = request.queryParameters["user"]
    val result = room?.let {
        synchronized(rooms) {
            room.expire()
            room.users.find { it?.id == id }?.let { user ->
                user.lastRequest = System.nanoTime()
                block(room, user)
            }
        }
    }
    if (result == null) respondText("not in room\n", status = HttpStatusCode.NotFound)
    else respondText(result)
}

// Answers each STUN Binding request (RFC 8489) with the sender's address in an
// XOR-MAPPED-ADDRESS. Java's socket is dual-stack and gives IPv4 senders as
// 4-byte addresses.
fun stun(port: Int) {
    val socket = DatagramSocket(port)
    val req = ByteArray(1500)
    val cookie = byteArrayOf(0x21, 0x12, 0xa4.toByte(), 0x42)
    while (true) {
        val packet = DatagramPacket(req, req.size)
        socket.receive(packet)
        if (packet.length < 20 || req[0] != 0.toByte() || req[1] != 1.toByte() ||
            !req.copyOfRange(4, 8).contentEquals(cookie)) continue

        // The request's cookie and transaction ID (req[4..19]), then
        // XOR-MAPPED-ADDRESS (type 0x0020), whose port is XORed with the
        // cookie's top 16 bits and address with the cookie and ID.
        val addr = packet.address.address
        val res = ByteArray(28 + addr.size)
        res[1] = 0x01
        res[0] = 0x01
        res[3] = (8 + addr.size).toByte()
        req.copyInto(res, 4, 4, 20)
        res[21] = 0x20
        res[23] = (4 + addr.size).toByte()
        res[25] = if (addr.size == 4) 1 else 2
        res[26] = ((packet.port shr 8) xor 0x21).toByte()
        res[27] = (packet.port xor 0x12).toByte()
        for (i in addr.indices) res[28 + i] = (addr[i].toInt() xor req[4 + i].toInt()).toByte()
        socket.send(DatagramPacket(res, res.size, packet.socketAddress))
    }
}

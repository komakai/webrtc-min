# stun-room

A combined STUN/signaling server for testing WebRTC on a LAN.
Runs on Linux and macOS, and Windows under WSL2. Requires JDK 17+

Run with default ports:
```sh
./gradlew run                       # HTTP on 8080, STUN on UDP 3478
```

Run with custom ports:

```sh
./gradlew run --args="9000 19302"   # alternative ports
```

## Running under WSL2

Enable mirrored networking by setting `networkingMode=mirrored`
under `[wsl2]` in the WSL config file at `%UserProfile%\.wslconfig` (create if doesn't exist) and restart WSL2 with `wsl --shutdown`

In Windows Powershell running as Administrator, open the ports required for STUN (default: 3478) and HTTP API requests (default: 8080)

```powershell
foreach ($r in @(@{P="TCP"; L=8080}, @{P="UDP"; L=3478})) {
  New-NetFirewallHyperVRule -Name "stun-room-$($r.P)" -DisplayName "stun-room $($r.P)" -Direction Inbound `
    -VMCreatorId '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}' -Protocol $r.P -LocalPorts $r.L
}
```

# Real fleet-telemetry payload fixtures

Captured with `mosquitto_sub -v -t 'garage/#'` against the Home Assistant
Mosquitto add-on while the Garage Bridge add-on (0.2.0) was streaming from a
2025 Model Y (fleet-telemetry v0.9.5, MQTT dispatcher). Each line is
`<topic> <payload>`.

Scrubbing applied before commit: VIN → `TESTVIN0000000001`, `Location`
coordinates → `51.5000,-0.1000`, `VehicleName` → `"Garage"`. Everything else
is verbatim. Raw captures (`live-*.log`) are git-ignored.

- `parked-2026-10-20.log` — ~10 min parked, awake, charger disconnected:
  all 32 configured fields (one each; parked values do not change), four
  `connectivity` events (CONNECTED/DISCONNECTED pairs as the car re-dials),
  and four alert `current` + `history` pairs whose `StartedAt`/`EndedAt`
  predate the capture (which is why `bridge_health.last_event_at` can show an
  old timestamp).

Observed shapes worth keeping in mind:

- Scalars are bare JSON: `33.07`, `true`, `"Idle"`, `"WindowStateClosed"`.
- Invalid/unavailable values arrive as literal `null` (`Gear`, `VehicleSpeed`,
  `ScheduledChargingStartTime` while parked); `SoftwareUpdateVersion` is `" "`
  when no update is pending.
- `Location` is `{"latitude":..,"longitude":..}`; `DoorState` is an object of
  six booleans (`TrunkFront`/`TrunkRear` included).
- `connectivity` is `{"ConnectionId","CreatedAt","Status"}`.

import Foundation
import Testing
@testable import GarageKit

@Suite struct VehicleStateDecodingTests {
    /// Every column of the real 2026-10-20 row decodes to the value in the fixture, including the
    /// `+00:00` timestamps (milli- and microsecond fractions) and the `Z`-suffixed `last_event_at`.
    @Test func decodesLiveRow() throws {
        let s = try Fixture.state("vehicle_state_live")

        #expect(s.vehicleId == UUID(uuidString: "e821390b-f84c-4cd4-a125-9f2f3188e45f"))
        #expect(s.ownerId == UUID(uuidString: "37b3272b-7899-45cf-8956-a156313b12cb"))
        #expect(s.soc == 33.93464052287582)
        #expect(s.rangeKm == 154.497024)
        #expect(s.chargeState == "disconnected")
        #expect(s.chargerPowerKw == 0)
        #expect(s.chargeLimitSoc == 90)
        #expect(s.chargePortOpen == false)
        #expect(s.scheduledChargeAt == nil)
        expectDate(s.chargeAt, 1_792_481_452.095)
        #expect(s.insideC == 8.500000722706318)
        #expect(s.outsideC == 10.5)
        #expect(s.hvacOn == false)
        #expect(s.climateKeeper == "ClimateKeeperModeStateOff")
        expectDate(s.climateAt, 1_792_481_507.807)
        #expect(s.lat == 51.5)
        #expect(s.lng == -0.1)
        #expect(s.heading == 268)
        #expect(s.speedKph == 0)
        #expect(s.gear == "P")
        #expect(s.odometerKm == 12851.535610415158)
        expectDate(s.locationAt, 1_792_481_452.091)
        #expect(s.locked == true)
        let closed = Doors(driverFront: false, passengerFront: false, driverRear: false, passengerRear: false)
        #expect(s.doors == closed)
        #expect(s.windows == Windows(driverFront: false, passengerFront: false, driverRear: false, passengerRear: false))
        #expect(s.frunkOpen == false)
        #expect(s.trunkOpen == false)
        expectDate(s.bodyAt, 1_792_481_452.094)
        #expect(s.tpmsBar == Tpms(fl: 3.1, fr: 2.65, rl: 2.7, rr: 2.8))
        #expect(s.sentry == false)
        #expect(s.sleepState == "online")
        #expect(s.softwareVersion == " ")
        expectDate(s.bridgeSeenAt, 1_792_481_486.773)
        let health = try #require(s.bridgeHealth)
        #expect(health.dropped == 0)
        #expect(health.flushed == 31)
        #expect(health.received == 36)
        #expect(health.connectivity == "CONNECTED")
        #expect(health.activeAlerts == [])
        expectDate(health.lastEventAt, 1_792_011_239.0)
        #expect(health.patchFailures == 0)
        expectDate(s.updatedAt, 1_792_481_509.132824)
        #expect(s.chargeAmps == 0)
    }

    /// A row carrying only its keys and `updated_at` decodes without throwing; everything else is nil.
    @Test func decodesSparseRow() throws {
        let s = try Fixture.state("vehicle_state_sparse")

        #expect(s.vehicleId == UUID(uuidString: "e821390b-f84c-4cd4-a125-9f2f3188e45f"))
        #expect(s.ownerId != nil)
        expectDate(s.updatedAt, 1_792_481_509.132824)

        var cleared = s
        cleared.vehicleId = nil
        cleared.ownerId = nil
        cleared.updatedAt = nil
        #expect(cleared == VehicleState())
    }
}

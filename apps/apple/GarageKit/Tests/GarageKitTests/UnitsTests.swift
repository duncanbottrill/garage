import Foundation
import Testing
@testable import GarageKit

@Suite struct UnitsTests {
    /// en_GB shows kilometres and Celsius; en_US shows miles and Fahrenheit.
    @Test func unitsFollowLocale() {
        let gb = Locale(identifier: "en_GB")
        let us = Locale(identifier: "en_US")

        let kmGB = Units.distance(km: 154.497024, locale: gb)
        #expect(kmGB.unit == UnitLength.kilometers)
        #expect(abs(kmGB.value - 154.497024) < 1e-9)

        let miUS = Units.distance(km: 154.497024, locale: us)
        #expect(miUS.unit == UnitLength.miles)
        #expect(abs(miUS.value - 96.0) < 0.01)

        let cGB = Units.temperature(c: 10.5, locale: gb)
        #expect(cGB.unit == UnitTemperature.celsius)
        #expect(abs(cGB.value - 10.5) < 1e-9)

        let fUS = Units.temperature(c: 10.5, locale: us)
        #expect(fUS.unit == UnitTemperature.fahrenheit)
        #expect(abs(fUS.value - 50.9) < 1e-9)
    }
}

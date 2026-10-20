import Foundation
import Testing
@testable import GarageKit

@Suite struct UnitsTests {
    /// Units follow the locale's measurement system: en_GB (UK system) is miles and Celsius, en_GB with
    /// the metric system is kilometres, en_US (US system) is miles and Fahrenheit.
    @Test func unitsFollowLocale() {
        let gb = Locale(identifier: "en_GB")
        let gbMetric = Locale(identifier: "en_GB@measure=metric")
        let us = Locale(identifier: "en_US")

        let miGB = Units.distance(km: 154.497024, locale: gb)
        #expect(miGB.unit == UnitLength.miles)
        #expect(abs(miGB.value - 96.0) < 0.01)

        let cGB = Units.temperature(c: 10.5, locale: gb)
        #expect(cGB.unit == UnitTemperature.celsius)
        #expect(abs(cGB.value - 10.5) < 1e-9)

        let kmMetric = Units.distance(km: 154.497024, locale: gbMetric)
        #expect(kmMetric.unit == UnitLength.kilometers)
        #expect(abs(kmMetric.value - 154.497024) < 1e-9)
        #expect(Units.temperature(c: 10.5, locale: gbMetric).unit == UnitTemperature.celsius)

        let miUS = Units.distance(km: 154.497024, locale: us)
        #expect(miUS.unit == UnitLength.miles)
        #expect(abs(miUS.value - 96.0) < 0.01)

        let fUS = Units.temperature(c: 10.5, locale: us)
        #expect(fUS.unit == UnitTemperature.fahrenheit)
        #expect(abs(fUS.value - 50.9) < 1e-9)
    }
}

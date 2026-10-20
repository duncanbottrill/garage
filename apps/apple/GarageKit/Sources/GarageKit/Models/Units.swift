import Foundation

/// Converts the database's metric values into the units the user's locale reads.
///
/// Only the US measurement system switches to miles and Fahrenheit. Metric and UK locales (en_GB)
/// keep kilometres and Celsius: the car and the Tesla app report range in km for this owner, and the
/// spec's en_GB acceptance shows km.
public enum Units {
    /// A distance stored in kilometres, in km or miles for `locale`.
    public static func distance(km: Double, locale: Locale = .current) -> Measurement<UnitLength> {
        let metric = Measurement(value: km, unit: UnitLength.kilometers)
        return usesUSUnits(locale) ? metric.converted(to: .miles) : metric
    }

    /// A temperature stored in Celsius, in °C or °F for `locale`.
    public static func temperature(c: Double, locale: Locale = .current) -> Measurement<UnitTemperature> {
        let metric = Measurement(value: c, unit: UnitTemperature.celsius)
        return usesUSUnits(locale) ? metric.converted(to: .fahrenheit) : metric
    }

    static func usesUSUnits(_ locale: Locale) -> Bool {
        locale.measurementSystem == .us
    }
}

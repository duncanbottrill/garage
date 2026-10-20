import Foundation

/// Converts the database's metric values into the units of the user's locale measurement system.
///
/// - `.us`: miles and Fahrenheit.
/// - `.uk`: miles and Celsius (UK roads use miles; the weather uses Celsius).
/// - `.metric`: kilometres and Celsius. A UK user who prefers km sets their region's measurement
///   system to metric (`en_GB@measure=metric`).
public enum Units {
    /// A distance stored in kilometres, in km or miles for `locale`.
    public static func distance(km: Double, locale: Locale = .current) -> Measurement<UnitLength> {
        let metric = Measurement(value: km, unit: UnitLength.kilometers)
        switch locale.measurementSystem {
        case .us, .uk: return metric.converted(to: .miles)
        default: return metric
        }
    }

    /// A temperature stored in Celsius, in °C or °F for `locale`.
    public static func temperature(c: Double, locale: Locale = .current) -> Measurement<UnitTemperature> {
        let metric = Measurement(value: c, unit: UnitTemperature.celsius)
        return locale.measurementSystem == .us ? metric.converted(to: .fahrenheit) : metric
    }
}

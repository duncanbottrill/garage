import CoreText
import Foundation

/// GarageKit: the logic and views of the Garage app. The app target is a thin shell around it.
public enum GarageKit {
    /// The bundled typefaces (SIL OFL 1.1), by file name. Big Shoulders Display sets the numerals,
    /// Instrument Sans the UI text.
    static let fontFiles = ["BigShouldersDisplay[wght].ttf", "InstrumentSans[wdth,wght].ttf"]

    /// Registers the bundled fonts for this process so `Font.custom` resolves them by family name.
    /// Safe to call any number of times, from any thread: the work runs once.
    public static func registerFonts() {
        _ = fontRegistration
    }

    /// A lazily initialised static runs exactly once, atomically, which is what makes `registerFonts` idempotent.
    private static let fontRegistration: Void = {
        for url in fontURLs() {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error), let error = error?.takeRetainedValue() {
                // Already registered (for example by a host that registered them first) is fine.
                if CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue {
                    assertionFailure("GarageKit: could not register \(url.lastPathComponent): \(error)")
                }
            }
        }
    }()

    /// Resource processing may flatten the Fonts folder into the bundle root, so both places are looked in.
    static func fontURLs() -> [URL] {
        fontFiles.compactMap { file in
            let name = (file as NSString).deletingPathExtension
            return Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: name, withExtension: "ttf")
        }
    }
}

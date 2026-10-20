import Foundation
import Testing
@testable import GarageKit

@Suite struct AppleNonceTests {
    @Test func hashedIsLowercaseHexSHA256OfRaw() {
        // FIPS 180-2 test vector.
        #expect(AppleNonce(raw: "abc").hashed == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func randomNoncesAreFreshAndURLSafe() {
        let a = AppleNonce.random()
        let b = AppleNonce.random()
        #expect(a.raw.count == 32)
        #expect(a != b)
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        #expect(a.raw.unicodeScalars.allSatisfy(allowed.contains))
    }

    @Test func vinSuffixIsLastSix() {
        #expect(VehicleStep.vinSuffix("LRWYGCEK0PC123456") == "123456")
        #expect(VehicleStep.vinSuffix("ABC") == "ABC")
    }
}

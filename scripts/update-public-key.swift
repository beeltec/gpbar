import Foundation
import CryptoKit

guard CommandLine.arguments.count == 2 else {
    throw CocoaError(.fileReadInvalidFileName)
}
let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
guard let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32 else {
    throw CocoaError(.fileReadCorruptFile)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())

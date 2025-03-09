//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CommonCrypto
import CryptoKit
import Foundation
public import LibSignalClient

public struct ProvisionMessage {
    public let accountEntropyPool: String?
    public let aci: Aci?
    public let phoneNumber: String
    public let pni: Pni?
    public let aciIdentityKeyPair: ECKeyPair
    public let pniIdentityKeyPair: ECKeyPair
    public let profileKey: Aes256Key
    public let masterKey: Data
    public let mrbk: Data?
    public let ephemeralBackupKey: Data?
    public let areReadReceiptsEnabled: Bool?
    public let primaryUserAgent: String?
    public let provisioningCode: String
    public let provisioningVersion: UInt32?
}

public enum ProvisioningError: Error {
    case invalidProvisionMessage(_ description: String)
}

public class ProvisioningCipher {

    public var secondaryDevicePublicKey: PublicKey {
        return secondaryDeviceKeyPair.publicKey
    }

    let secondaryDeviceKeyPair: IdentityKeyPair
    init(secondaryDeviceKeyPair: IdentityKeyPair) {
        self.secondaryDeviceKeyPair = secondaryDeviceKeyPair
    }

    public class func generate() -> ProvisioningCipher {
        return ProvisioningCipher(secondaryDeviceKeyPair: IdentityKeyPair.generate())
    }

    internal class var messageInfo: String {
        return "TextSecure Provisioning Message"
    }

    public func decrypt(envelope: ProvisioningProtoProvisionEnvelope) throws -> ProvisionMessage {
        let primaryDeviceEphemeralPublicKey = try PublicKey(envelope.publicKey)
        let bytes = [UInt8](envelope.body)

        let versionLength = 1
        let ivLength = 16
        let macLength = 32
        let provisionMessageLength = bytes.count - versionLength - ivLength - macLength
        guard provisionMessageLength > 0 else {
            throw ProvisioningError.invalidProvisionMessage("provisioning message too short.")
        }

        let version = bytes[0]
        guard version == 1 else {
            throw ProvisioningError.invalidProvisionMessage("Unexpected version on provisioning message: \(bytes[0])")
        }

        let iv = Array(bytes[1..<17])
        let theirMac = bytes.suffix(32)
        let messageToAuthenticate = bytes[0..<(bytes.count - 32)]
        let ciphertext = Array(bytes[17..<(bytes.count - 32)])

        let agreement = secondaryDeviceKeyPair.privateKey.keyAgreement(
            with: primaryDeviceEphemeralPublicKey)

        let keyBytes = try Self.messageInfo.utf8.withContiguousStorageIfAvailable {
            try hkdf(outputLength: 64, inputKeyMaterial: agreement, salt: [], info: $0)
        }!

        let cipherKey = Array(keyBytes[0..<32])
        let macKey = keyBytes[32..<64]

        let ourHMAC = Data(HMAC<SHA256>.authenticationCode(for: messageToAuthenticate, using: .init(data: macKey)))
        guard ourHMAC.ows_constantTimeIsEqual(to: Data(theirMac)) else {
            throw ProvisioningError.invalidProvisionMessage("mac mismatch")
        }

        var bytesDecrypted: size_t = 0
        var plaintextBuffer: [UInt8] = [UInt8].init(repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        let cryptStatus = CCCrypt(CCOperation(kCCDecrypt),
                                  CCAlgorithm(kCCAlgorithmAES128),
                                  CCOptions(kCCOptionPKCS7Padding),
                                  cipherKey,
                                  cipherKey.count,
                                  iv,
                                  ciphertext,
                                  ciphertext.count,
                                  &plaintextBuffer,
                                  plaintextBuffer.count,
                                  &bytesDecrypted)

        guard cryptStatus == kCCSuccess else {
            throw OWSAssertionError("failure with cryptStatus: \(cryptStatus)")
        }

        let plaintext = Data(plaintextBuffer.prefix(upTo: bytesDecrypted))
        let proto = try ProvisioningProtoProvisionMessage(serializedData: plaintext)

        let aciIdentityKeyPair = try IdentityKeyPair(publicKey: PublicKey(proto.aciIdentityKeyPublic),
                                                     privateKey: PrivateKey(proto.aciIdentityKeyPrivate))
        let pniIdentityKeyPair = try IdentityKeyPair(publicKey: PublicKey(proto.pniIdentityKeyPublic),
                                                     privateKey: PrivateKey(proto.pniIdentityKeyPrivate))

        guard let profileKey = Aes256Key(data: proto.profileKey) else {
            throw ProvisioningError.invalidProvisionMessage("invalid profileKey - count: \(proto.profileKey.count)")
        }
        let areReadReceiptsEnabled = proto.hasReadReceipts ? proto.readReceipts : nil
        let primaryUserAgent = proto.hasUserAgent ? proto.userAgent : nil
        let provisioningCode = proto.provisioningCode
        let provisioningVersion = proto.hasProvisioningVersion ? proto.provisioningVersion : nil

        guard let phoneNumber = proto.number, phoneNumber.count > 1 else {
            throw ProvisioningError.invalidProvisionMessage("missing number from provisioning message")
        }

        let aci: Aci? = try {
            guard proto.hasAci, let aciString = proto.aci else { return nil }
            guard let aci = Aci.parseFrom(aciString: aciString) else {
                throw ProvisioningError.invalidProvisionMessage("invalid ACI from provisioning message")
            }
            return aci
        }()

        let pni: Pni? = try {
            guard proto.hasPni, let pniString = proto.pni else { return nil }
            guard let pni = Pni.parseFrom(ambiguousString: pniString) else {
                throw ProvisioningError.invalidProvisionMessage("invalid PNI from provisioning message")
            }
            return pni
        }()

        guard let masterKey = proto.masterKey else {
            throw ProvisioningError.invalidProvisionMessage("missing master key from provisioning message")
        }

        let accountEntropyPool = proto.accountEntropyPool?.nilIfEmpty
        let mediaRootBackupKey = proto.mediaRootBackupKey?.nilIfEmpty
        let ephemeralBackupKey = proto.ephemeralBackupKey

        return ProvisionMessage(
            accountEntropyPool: accountEntropyPool,
            aci: aci,
            phoneNumber: phoneNumber,
            pni: pni,
            aciIdentityKeyPair: ECKeyPair(aciIdentityKeyPair),
            pniIdentityKeyPair: ECKeyPair(pniIdentityKeyPair),
            profileKey: profileKey,
            masterKey: masterKey,
            mrbk: mediaRootBackupKey,
            ephemeralBackupKey: ephemeralBackupKey,
            areReadReceiptsEnabled: areReadReceiptsEnabled,
            primaryUserAgent: primaryUserAgent,
            provisioningCode: provisioningCode,
            provisioningVersion: provisioningVersion
        )
    }
}

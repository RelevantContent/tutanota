import { assertWorkerOrNode } from "../../common/Env"
import { AesKey, AsymmetricKeyPair, EccPublicKey, isPqKeyPairs, isRsaOrRsaEccKeyPair, RsaPrivateKey, uint8ArrayToBitArray } from "@tutao/tutanota-crypto"
import type { RsaImplementation } from "./RsaImplementation"
import { PQFacade } from "../facades/PQFacade.js"
import { CryptoError } from "@tutao/tutanota-crypto/error.js"

assertWorkerOrNode()

export type DecapsulatedAesKey = {
	decryptedAesKey: AesKey
	senderIdentityPubKey: EccPublicKey | null // null for rsa only
}

export class AsymmetricCryptoFacade {
	constructor(private readonly rsa: RsaImplementation, private readonly pqFacade: PQFacade) {}

	async decryptSymKeyWithKeyPair(keyPair: AsymmetricKeyPair, pubEncBucketKey: Uint8Array): Promise<DecapsulatedAesKey> {
		const algo = keyPair.keyPairType
		if (isPqKeyPairs(keyPair)) {
			const decryptedBucketKey = await this.pqFacade.decapsulateEncoded(pubEncBucketKey, keyPair)
			return {
				decryptedAesKey: uint8ArrayToBitArray(decryptedBucketKey.decryptedSymKeyBytes),
				senderIdentityPubKey: decryptedBucketKey.senderIdentityPubKey,
			}
		} else if (isRsaOrRsaEccKeyPair(keyPair)) {
			const privateKey: RsaPrivateKey = keyPair.privateKey
			const decryptedBucketKey = await this.rsa.decrypt(privateKey, pubEncBucketKey)
			return {
				decryptedAesKey: uint8ArrayToBitArray(decryptedBucketKey),
				senderIdentityPubKey: null,
			}
		} else {
			throw new CryptoError("unknown key pair type: " + algo)
		}
	}
}

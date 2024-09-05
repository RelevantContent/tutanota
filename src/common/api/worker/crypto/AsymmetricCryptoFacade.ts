import { assertWorkerOrNode } from "../../common/Env"
import { AsymmetricKeyPair, isPqKeyPairs, isRsaOrRsaEccKeyPair, RsaPrivateKey, uint8ArrayToBitArray } from "@tutao/tutanota-crypto"
import type { RsaImplementation } from "./RsaImplementation"
import { PQFacade } from "../facades/PQFacade.js"
import { CryptoError } from "@tutao/tutanota-crypto/error.js"

assertWorkerOrNode()

export class AsymmetricCryptoFacade {
	constructor(private readonly rsa: RsaImplementation, private readonly pqFacade: PQFacade) {}

	async decryptSymKeyWithKeyPair(keyPair: AsymmetricKeyPair, pubEncBucketKey: Uint8Array) {
		const algo = keyPair.keyPairType
		if (isPqKeyPairs(keyPair)) {
			const decryptedBucketKey = await this.pqFacade.decapsulateEncoded(pubEncBucketKey, keyPair)
			return {
				decryptedBucketKey: uint8ArrayToBitArray(decryptedBucketKey.decryptedSymKey),
				pqMessageSenderIdentityPubKey: decryptedBucketKey.senderIdentityPubKey,
			}
		} else if (isRsaOrRsaEccKeyPair(keyPair)) {
			const privateKey: RsaPrivateKey = keyPair.privateKey
			const decryptedBucketKey = await this.rsa.decrypt(privateKey, pubEncBucketKey)
			return {
				decryptedBucketKey: uint8ArrayToBitArray(decryptedBucketKey),
				pqMessageSenderIdentityPubKey: null,
			}
		} else {
			throw new CryptoError("unknown key pair type: " + algo)
		}
	}
}

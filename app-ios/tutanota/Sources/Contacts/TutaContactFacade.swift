import Contacts
import DictionaryCoding
import Foundation

private let CONTACTS_MAPPINGS = "ContactsMappings"

/// Manages the available `UserContactMapping`s and provides functionality to handle non-Tuta contacts
class TutaContactFacade {
	private let nativeContactStoreFacade: NativeContactStoreFacade
	private let userDefaults: UserDefaults

	init(userDefault: UserDefaults) {
		nativeContactStoreFacade = NativeContactStoreFacade()
		self.userDefaults = userDefault
	}

	/// Returns the local container from the `NativeContactStoreFacade`
	func getLocalContainer() -> String { nativeContactStoreFacade.getLocalContainer() }

	private func getMappingsDictionary() -> [String: [String: Any]] {
		self.userDefaults.dictionary(forKey: CONTACTS_MAPPINGS) as! [String: [String: Any]]? ?? [:]
	}

	/// Returns a contact list from the mappings dictionary and migrates it if necessary
	func getContactList(username: String) -> UserContactList? {
		if var dict = getMappingsDictionary()[username] {
			// migration from the version that didn't have hashes
			if dict["localContactIdentifierToHash"] == nil { dict["localContactIdentifierToHash"] = [String: UInt32]() }
			if dict["stableHash"] == nil {
				TUTSLog("Migrating old unstable hashes")
				// Map old values Int64 to a truncated UInt32 hash
				dict["localContactIdentifierToHash"] = (dict["localContactIdentifierToHash"] as! [String: Int]).mapValues { UInt32($0 & 0xFFFFFFFF) }
				dict["stablehash"] = true
			}
			let mapping = try! DictionaryDecoder().decode(UserContactMapping.self, from: dict)
			return try! UserContactList(nativeContactStoreFacade: self.nativeContactStoreFacade, username: username, mappingData: mapping, stableHash: true)
		} else {
			return nil
		}
	}

	/// Inserts a contact list into the mappings dictionary
	func saveContactList(_ contactList: UserContactList) {
		var dict = getMappingsDictionary()
		let mapping = contactList.getMapping()
		dict[mapping.username] = try! DictionaryEncoder().encode(mapping)
		self.userDefaults.setValue(dict, forKey: CONTACTS_MAPPINGS)
	}

	/// Removes a contact list from the mappings dictionary and deletes the associated group from the contact store
	func deleteContactList(_ contactList: UserContactList) throws {
		let group = try contactList.getTutaContactGroup()
		var dict = getMappingsDictionary()
		let mapping = contactList.getMapping()
		dict.removeValue(forKey: mapping.username)
		self.userDefaults.setValue(dict, forKey: CONTACTS_MAPPINGS)
		try self.nativeContactStoreFacade.deleteCNGroup(forGroup: group)
	}

	func getOrCreateContactList(username: String) throws -> UserContactList {
		if let mapping = self.getContactList(username: username) {
			return mapping
		} else {
			TUTSLog("MobileContactsFacade: creating new mapping for \(username)")
			let mapping = try UserContactList(nativeContactStoreFacade: self.nativeContactStoreFacade, username: username, mappingData: nil, stableHash: true)
			self.saveContactList(mapping)
			return mapping
		}
	}

	/// Returns all contacts in the iOS contact store
	func getAllContacts(withSorting desiredSorting: CNContactSortOrder?) throws -> [StructuredContact] {
		try nativeContactStoreFacade.getAllContacts(inGroup: nil, withSorting: desiredSorting)
			.map { nativeContact in nativeContact.toStructuredContact(serverId: nil) }
	}

	func queryContactSuggestions(query: String, upTo: Int) throws -> [ContactSuggestion] {
		try nativeContactStoreFacade.queryContactSuggestions(query: query, upTo: upTo)
	}

	/// Returns any contacts outside the Tuta contact list specified by `username` that match contacts inside that Tuta contact list
	func getDuplicateContacts(_ username: String) async throws -> [StructuredContact] {
		let contactList = self.getContactList(username: username)!
		let mapping = contactList.getMapping()

		var contacts = [StructuredContact]()
		for contact in try self.nativeContactStoreFacade.getAllContacts(inGroup: nil, withSorting: nil) {
			let iOSId = contact.identifier
			if mapping.localContactIdentifierToHash[iOSId] != nil {
				let serverId = mapping.localContactIdentifierToServerId[iOSId]
				contacts.append(contact.toStructuredContact(serverId: serverId))
			}
		}

		return contacts
	}

	/// Returns whether the local contact container is available
	func isLocalStorageAvailable() -> Bool { nativeContactStoreFacade.isLocalStorageAvailable() }

}

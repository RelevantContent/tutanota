import Contacts
import DictionaryCoding

// Maps a Tuta ID to a native or structured contact
private typealias TutaToNativeContactIdentifiers = [String: String]
private typealias TutaToNativeContacts = [String: NativeMutableContact]
private typealias TutaToStructuredContacts = [String: StructuredContact]

private let CONTACT_BOOK_ID = "APPLE_DEFAULT"

/// Handles synchronization between contacts in Tuta and contacts on the device.
class IosMobileContactsFacade: MobileContactsFacade {
	private let userDefaults: UserDefaults
	private let contactFacade: TutaContactFacade

	init(userDefault: UserDefaults) {
		self.userDefaults = userDefault
		self.contactFacade = TutaContactFacade(userDefault: userDefault)
	}

	func findSuggestions(_ query: String) async throws -> [ContactSuggestion] {
		try await acquireContactsPermission()
		return try self.queryContactSuggestions(query: query, upTo: 10)
	}

	func saveContacts(_ username: String, _ contacts: [StructuredContact]) async throws {
		TUTSLog("MobileContactsFacade: save with \(contacts.count) contacts")
		try await acquireContactsPermission()
		let contactList = try self.contactFacade.getOrCreateContactList(username: username)
		let mapping = contactList.getMapping()
		let queryResult = try self.matchStoredContacts(against: contacts, forUser: contactList)
		// Here is ok to have an equal count of deletedOnDevice and deletedOnServer since not all server contacts and not all local contacts are inside the contacts array
		TUTSLog(
			"Contact SAVE match result: editedOnDevice: \(queryResult.editedOnDevice.count) newServerContacts: \(queryResult.newServerContacts.count) existingServerContacts: \(queryResult.existingServerContacts.count) nativeContactWithoutSourceId: \(queryResult.nativeContactWithoutSourceId.count)"
		)
		try contactList.insert(contacts: queryResult.newServerContacts)
		try contactList.update(contacts: queryResult.existingServerContacts)
		try contactList.insert(contacts: queryResult.nativeContactWithoutSourceId.map {
			let serverId = $0.serverId
			return $0.contact.toStructuredContact(serverId: serverId)
		})

		// The hash will not match and that's expected as we already returned it as edited on device in sync,
		// but we need to update those contacts, too, if they are passed to us.
		try contactList.update(contacts: queryResult.editedOnDevice)

		self.contactFacade.saveContactList(contactList)
		TUTSLog("Contact SAVE finished")
	}

	private func getDuplicateContacts(_ username: String) async throws -> [StructuredContact] {
		let store = CNContactStore()
		let containers = try store.containers(matching: nil)
		guard let localContainer = containers.first(where: { $0.type == CNContainerType.local }) else {
			throw TUTErrorFactory.createError("No local container present for contacts.")
		}
		let fetch = makeContactFetchRequest()
		fetch.sortOrder = CNContactSortOrder.givenName
		let mapping = self.contactFacade.getContactList(username: username)!

		var contacts = [StructuredContact]()
		try self.enumerateContactsInContactStore(store, with: fetch) { (contact, _) in
			let iOSId = contact.identifier
			if mapping.localContactIdentifierToHash[iOSId] != nil {
				let serverId = mapping.localContactIdentifierToServerId[iOSId]
				contacts.append(contact.toStructuredContact(serverId: serverId))
			}
		}
		return contacts
	}

	func syncContacts(_ username: String, _ contacts: [StructuredContact]) async throws -> ContactSyncResult {
		TUTSLog("MobileContactsFacade: sync with \(contacts.count) contacts")
		try await acquireContactsPermission()
		let contactList = try self.contactFacade.getOrCreateContactList(username: username)
		let matchResult = try self.matchStoredContacts(against: contacts, forUser: contactList)

		TUTSLog(
			"Contact SYNC result: createdOnDevice: \(matchResult.createdOnDevice.count) editedOnDevice: \(matchResult.editedOnDevice.count) deletedOnDevice: \(matchResult.deletedOnDevice.count) newServerContacts: \(matchResult.newServerContacts.count) deletedOnServer: \(matchResult.deletedOnServer.count) existingServerContacts: \(matchResult.existingServerContacts.count) nativeContactWithoutSourceId: \(matchResult.nativeContactWithoutSourceId.count)"
		)
		try contactList.insert(contacts: matchResult.newServerContacts)
		if !matchResult.deletedOnServer.isEmpty { try contactList.delete(contactsWithServerIDs: matchResult.deletedOnServer) }
		try contactList.update(contacts: matchResult.existingServerContacts)

		// Get any local contacts that are duplicates of contacts in our backend
		let duplicateContacts = try await getDuplicateContacts(username)
		let duplicateResult = try self.matchStoredContacts(against: duplicateContacts, forUser: contactList)

//		let existingContactIds = duplicateResult.existingServerContacts.map {
//			_, contact in contact.id!
//		}
//		try self.delete(contactsWithServerIDs: existingContactIds, forUser: &mapping)

		// Update the iOS IDs of contacts in the Tuta list to match the IDs in the local container
//		let mergedContacts = duplicateResult.existingServerContacts.map { nativeContact, contact in
//			let localId = nativeContact.localIdentifier
//			let updatedNativeContact = {...nativeContact, localIdentifier: localId}
//			return (updatedNativeContact, contact)
//		}
//		try self.update(contacts: mergedContacts, forUser: &mapping)

//		let (testContact, _) = duplicateResult.existingServerContacts.first!
//		testContact.contact.isUnifiedWithContact(withIdentifier: <#T##String#>)

		// For sync it normally wouldn't happen that we have a contact without source/server id but for existing contacts without
		// hashes we want to write the hashes on the first run so we reuse this field.
		try contactList.insert(contacts: matchResult.nativeContactWithoutSourceId.map {
			let serverId = $0.serverId
			return $0.contact.toStructuredContact(serverId: serverId)
		})

		self.contactFacade.saveContactList(contactList)
		TUTSLog("Contact SYNC finished")

		return ContactSyncResult(
			createdOnDevice: matchResult.createdOnDevice,
			editedOnDevice: matchResult.editedOnDevice.map { (nativeContact, _) in nativeContact.contact.toStructuredContact(serverId: nativeContact.serverId)
			},
			deletedOnDevice: matchResult.deletedOnDevice
		)
	}

	func getContactBooks() async throws -> [ContactBook] {
		try await acquireContactsPermission()
		// we can't effectively query containers so we just pretend that we have one book
		return [ContactBook(id: CONTACT_BOOK_ID, name: "")]
	}

	func getContactsInContactBook(_ containerId: String, _ username: String) async throws -> [StructuredContact] {
		// assert(containerId == CONTACT_BOOK_ID, "Invalid contact book: \(containerId)")
		try await acquireContactsPermission()

		let fetch = makeContactFetchRequest()
		fetch.sortOrder = CNContactSortOrder.givenName

		let store = CNContactStore()
		var addresses = [StructuredContact]()
		let contactList = self.contactFacade.getContactList(username: username)
		try self.enumerateContactsInContactStore(store, with: fetch) { (contact, _) in
			if contactList?.localContactIdentifierToHash[contact.identifier] == nil {
				// we don't need (and probably don't have?) a server id in this case
				addresses.append(contact.toStructuredContact(serverId: nil))
			}
		}

		return addresses
	}

	func deleteContacts(_ username: String, _ contactId: String?) async throws {
		try await acquireContactsPermission()

		let mapping = try self.contactFacade.getOrCreateContactList(username: username)
		if let contactId {
			try mapping.delete(contactsWithServerIDs: [contactId])
			self.contactFacade.saveContactList(mapping)
		} else {
			try self.contactFacade.deleteContactList(mapping)
		}
	}

	func isLocalStorageAvailable() async throws -> Bool {
		let store = CNContactStore()

		do {
			let containers = try store.containers(matching: nil)
			TUTSLog("Contact containers: \(containers.map { "\($0.name) \($0.type) \($0.type.rawValue)" }.joined(separator: ","))")

			// Apple allow just ONE local container, so we can query for the first and unique one
			return containers.contains(where: { $0.type == CNContainerType.local })
		} catch {
			TUTSLog("Failed to fetch containers: \(error)")
			return false
		}
	}

	private func matchStoredContacts(against contacts: [StructuredContact], forUser list: UserContactList) throws -> MatchContactResult {
		// prepare the result
		var queryResult = MatchContactResult()

		let user = list.getMapping()

		// Group contacts by id. As we iterate over contacts we will remove the matched one from this dictionary
		var contactsById = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
		// Make a copy, we will remove matched contacts from it. All unmatched ones are assumed to be deleted by user
		var nativeContactIdentifierToHash = user.localContactIdentifierToHash

		// Enumerate all contacts in our group
		let storedContacts = try list.getAllContacts()
		for nativeContact in storedContacts {
			if let serverContactId = user.localContactIdentifierToServerId[nativeContact.identifier] {
				if let serverContact = contactsById.removeValue(forKey: serverContactId) {
					let structuredNative = nativeContact.toStructuredContact(serverId: serverContactId)
					let nativeMutableContact = NativeMutableContact(existingContact: nativeContact, serverId: serverContactId, container: contactFacade.getLocalContainer())
					let expectedHash = nativeContactIdentifierToHash.removeValue(forKey: nativeContact.identifier)
					// We check for nil so that existing contacts without hashes (from the first version without two-way sync)
					// won't get all updated on the server. We just want to write the mapping on the first run.
					if expectedHash == nil {
						queryResult.nativeContactWithoutSourceId.append(nativeMutableContact)
					} else if structuredNative.stableHash() != expectedHash {
						TUTSLog("MobileContactsFacade: hash mismatch for \(nativeContact.identifier) \(serverContactId)")
						queryResult.editedOnDevice.append((nativeMutableContact, serverContact))
					} else {
						queryResult.existingServerContacts.append((nativeMutableContact, serverContact))
					}
				} else {
					queryResult.deletedOnServer.append(serverContactId)
				}
			} else {
				let serverContactWithMatchingRawId = contacts.first { $0.rawId == nativeContact.identifier }
				if let serverId = serverContactWithMatchingRawId?.id {
					TUTSLog("MobileContactsFacade: Matched contact \(nativeContact.identifier) to server contact \(serverId) by raw id")
					contactsById.removeValue(forKey: serverId)
					queryResult.nativeContactWithoutSourceId.append(
						NativeMutableContact(existingContact: nativeContact, serverId: serverId, container: contactFacade.getLocalContainer())
					)
				} else {
					queryResult.createdOnDevice.append(nativeContact.toStructuredContact(serverId: nil))
				}
			}
		}

		// These ones are deleted from device because we still have hashes for them.
		queryResult.deletedOnDevice = nativeContactIdentifierToHash.keys.compactMap { identifier in user.localContactIdentifierToServerId[identifier] }

		queryResult.newServerContacts = Array(contactsById.values)
		TUTSLog("MobileContactsFacade: New server contacts: \(queryResult.newServerContacts.count)")
		return queryResult
	}

	private func queryContactSuggestions(query: String, upTo: Int) throws -> [ContactSuggestion] {
		let contactsStore = CNContactStore()
		let keysToFetch: [CNKeyDescriptor] = [
			CNContactEmailAddressesKey as NSString,  // only NSString is CNKeyDescriptor
			CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
		]
		let request = makeContactFetchRequest(forKeys: keysToFetch)
		var result = [ContactSuggestion]()
		// This method is synchronous. Enumeration prevents having all accounts in memory at once.
		// We are doing the search manually because we can cannot combine predicates.
		// Alternatively we could query for email and query for name separately and then combine the results
		try self.enumerateContactsInContactStore(contactsStore, with: request) { contact, stopPointer in
			let name: String = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
			let matchesName = name.range(of: query, options: .caseInsensitive) != nil
			for address in contact.emailAddresses {
				let addressString = address.value as String
				if matchesName || addressString.range(of: query, options: .caseInsensitive) != nil {
					result.append(ContactSuggestion(name: name, mailAddress: addressString))
				}
				if result.count > upTo { stopPointer.initialize(to: true) }
			}
		}
		return result
	}
}

private struct MatchContactResult {
	/** do not exist on the device yet but exists on the server */
	var newServerContacts: [StructuredContact] = []
	/** exist on the device and the server and are not marked as dirty */
	var existingServerContacts: [(NativeMutableContact, StructuredContact)] = []
	/** contacts that exist on the device and on the server but we did not map them via sourceId yet */
	var nativeContactWithoutSourceId: [NativeMutableContact] = []
	/** exists on native (and is not marked deleted or dirty) but doesn't exist on the server anymore */
	var deletedOnServer: [String] = []
	/** exist in both but are marked as dirty */
	var editedOnDevice: [(NativeMutableContact, StructuredContact)] = []
	/** exists on the device but not on the server (and marked as dirty) */
	var createdOnDevice: [StructuredContact] = []
	/** exists on the server but marked as deleted (and dirty) on the device */
	var deletedOnDevice: [String] = []
}


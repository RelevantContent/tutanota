//
//  TutaContactFacade.swift
//  tutanota
//
//  Created by Tutao GmbH on 03.09.24.
//

import Foundation

class TutaContactFacade {
	
	private func getMappingsDictionary() -> [String: [String: Any]] {
		self.userDefaults.dictionary(forKey: CONTACTS_MAPPINGS) as! [String: [String: Any]]? ?? [:]

	}

	private func getMapping(username: String) -> UserContactMapping? {
		if var dict = getMappingsDictionary()[username] {
			// migration from the version that didn't have hashes
			if dict["localContactIdentifierToHash"] == nil { dict["localContactIdentifierToHash"] = [String: UInt32]() }
			if dict["stableHash"] == nil {
				TUTSLog("Migrating old unstable hashes")
				// Map old values Int64 to a truncated UInt32 hash
				dict["localContactIdentifierToHash"] = (dict["localContactIdentifierToHash"] as! [String: Int]).mapValues { UInt32($0 & 0xFFFFFFFF) }
				dict["stablehash"] = true
			}
			return try! DictionaryDecoder().decode(UserContactMapping.self, from: dict)
		} else {
			return nil
		}
	}

	private func saveMapping(_ mapping: UserContactMapping, forUsername username: String) {
		var dict = getMappingsDictionary()
		dict[username] = try! DictionaryEncoder().encode(mapping)
		self.userDefaults.setValue(dict, forKey: CONTACTS_MAPPINGS)
	}

	private func deleteMapping(forUsername username: String) {
		var dict = getMappingsDictionary()
		dict.removeValue(forKey: username)
		self.userDefaults.setValue(dict, forKey: CONTACTS_MAPPINGS)
	}

	/// Gets the Tuta contact group, creating it if it does not exist.
	private func getTutaContactGroup(forUser mapping: inout UserContactMapping) throws -> CNGroup {
		let store = CNContactStore()

		let result = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [mapping.systemGroupIdentifier]))
		if !result.isEmpty {
			return result[0]
		} else {
			TUTSLog("can't get tuta contact group \(mapping.username) from native: likely deleted by user")

			let newGroup = try self.createCNGroup(username: mapping.username)

			// update mapping right away so that everyone down the road will be using an updated version
			mapping.systemGroupIdentifier = newGroup.identifier
			// if the group is not there none of the mapping values make sense anymore
			mapping.localContactIdentifierToServerId = [:]
			mapping.localContactIdentifierToHash = [:]

			// save the mapping right away so that if something later fails we won;t have a dangling group
			self.saveMapping(mapping, forUsername: mapping.username)
			return newGroup
		}
	}

	private func getOrCreateMapping(username: String) throws -> UserContactMapping {
		if let mapping = self.getMapping(username: username) {
			return mapping
		} else {
			TUTSLog("MobileContactsFacade: creating new mapping for \(username)")
			let newGroup = try self.createCNGroup(username: username)
			let mapping = UserContactMapping(
				username: username,
				systemGroupIdentifier: newGroup.identifier,
				localContactIdentifierToServerId: [:],
				localContactIdentifierToHash: [:],
				stableHash: true
			)

			self.saveMapping(mapping, forUsername: username)
			return mapping
		}
	}
	func insert(contacts: [StructuredContact], forUser user: inout UserContactMapping) {
		let contactGroup = try self.getTutaContactGroup(forUser: &user)
		
		// We need store mapping from our contact id to native contact id but we get it only after actually saving the contacts,
		// so until we execute the save request we keep track of the mapping
		var insertedContacts = [(NativeMutableContact, StructuredContact)]()
		for newContact in contacts {
			if let contactId = newContact.id {
				let nativeContact = NativeMutableContact(newContactWithServerId: contactId, container: localContainer)
				nativeContact.updateContactWithData(newContact)
				insertedContacts.append((nativeContact, newContact))
			}
		}

		NativeContactStoreFacade().insert(contacts: insertedContacts.map {$0.0}, toGroup: contactGroup)

		for (nativeContact, structuredContact) in insertedContacts {
			user.localContactIdentifierToServerId[nativeContact.contact.identifier] = structuredContact.id
			user.localContactIdentifierToHash[nativeContact.contact.identifier] = structuredContact.stableHash()
		}
	}
}

extension CNContact {
	func toStructuredContact(serverId: String?) -> StructuredContact {
		StructuredContact(
			id: serverId,
			firstName: givenName,
			lastName: familyName,
			nickname: nickname,
			company: organizationName,
			birthday: birthday?.toIso(),
			mailAddresses: emailAddresses.map { $0.toStructuredMailAddress() },
			phoneNumbers: phoneNumbers.map { $0.toStructuredPhoneNumber() },
			addresses: postalAddresses.map { $0.toStructuredAddress() },
			rawId: identifier,
			customDate: dates.map { $0.toStructuredCustomDate() },
			department: departmentName,
			messengerHandles: instantMessageAddresses.map { $0.toStructuredMessengerHandle() },
			middleName: middleName,
			nameSuffix: nameSuffix,
			phoneticFirst: phoneticGivenName,
			phoneticLast: phoneticFamilyName,
			phoneticMiddle: phoneticMiddleName,
			relationships: contactRelations.map { $0.toStructuredRelationship() },
			websites: urlAddresses.map { $0.toStructuredWebsite() },
			notes: "",  // TODO: add when contact notes entitlement is obtained
			title: namePrefix,
			role: jobTitle
		)
	}
}

//
//  TutaContactFacade.swift
//  tutanota
//
//  Created by Tutao GmbH on 03.09.24.
//

import Contacts
import DictionaryCoding
import Foundation

private let CONTACTS_MAPPINGS = "ContactsMappings"

/// Manages the available `UserContactMapping`s
class TutaContactFacade {
	private let nativeContactStoreFacade: NativeContactStoreFacade
	private let userDefaults: UserDefaults

	init(userDefault: UserDefaults) {
		nativeContactStoreFacade = NativeContactStoreFacade()
		self.userDefaults = userDefault
	}

	func getLocalContainer() -> String { nativeContactStoreFacade.getLocalContainer() }

	private func getMappingsDictionary() -> [String: [String: Any]] {
		self.userDefaults.dictionary(forKey: CONTACTS_MAPPINGS) as! [String: [String: Any]]? ?? [:]
	}

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

	func saveContactList(_ contactList: UserContactList) {
		var dict = getMappingsDictionary()
		let mapping = contactList.getMapping()
		dict[mapping.username] = try! DictionaryEncoder().encode(mapping)
		self.userDefaults.setValue(dict, forKey: CONTACTS_MAPPINGS)
	}

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

	func getAllContacts(withSorting desiredSorting: CNContactSortOrder?) throws -> [StructuredContact] {
		try nativeContactStoreFacade.getAllContacts(inGroup: nil, withSorting: desiredSorting)
			.map { nativeContact in nativeContact.toStructuredContact(serverId: nil) }
	}

	/// Gets contacts from the devices which are not a part of a Tuta contact list
	func getUnhandledContacts() {

	}

	func queryContactSuggestions(query: String, upTo: Int) throws -> [ContactSuggestion] {
		try nativeContactStoreFacade.queryContactSuggestions(query: query, upTo: upTo)
	}

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

	func isLocalStorageAvailable() -> Bool { nativeContactStoreFacade.isLocalStorageAvailable() }

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

extension DateComponents {
	func toIso() -> String? {
		if let year, let month, let day {
			String(format: "%04d-%02d-%02d", year, month, day)
		} else if let month, let day {
			String(format: "--%02d-%02d", month, day)
		} else {
			nil
		}
	}
	static func fromIso(_ iso: String) -> DateComponents? {
		guard let date = Date.fromIso(iso) else { return nil }
		return Calendar(identifier: Calendar.Identifier.gregorian).dateComponents([.year, .day, .month], from: date)
	}
}

extension Date {
	static func fromIso(_ iso: String) -> Date? {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withFullDate]

		return formatter.date(from: iso)
	}
}

extension NSDateComponents {
	func toIso() -> String { String(format: "%04d-%02d-%02d", year, month, day) }
	static func fromIso(_ iso: String) -> NSDateComponents? {
		guard let date = DateComponents.fromIso(iso) else { return nil }
		return date as NSDateComponents
	}
}

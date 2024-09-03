//
//  NativeContactFacade.swift
//  tutanota
//
//  Created by Tutao GmbH on 03.09.24.
//

import Foundation
import Contacts

private let ALL_SUPPORTED_CONTACT_KEYS: [CNKeyDescriptor] =
	[
		CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey, CNContactBirthdayKey,
		CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactPostalAddressesKey, CNContactDatesKey, CNContactDepartmentNameKey,
		CNContactInstantMessageAddressesKey, CNContactMiddleNameKey, CNContactNameSuffixKey, CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey,
		CNContactPhoneticFamilyNameKey, CNContactRelationsKey, CNContactUrlAddressesKey, CNContactNamePrefixKey, CNContactJobTitleKey,
	] as [CNKeyDescriptor]

/// Provides a simplified interface for the iOS Contacts framework
class NativeContactStoreFacade {

	/// Query the local container, ignoring the user's choices for the default contacts location.
	/// This prevent other apps, as Gmail or even iCloud, from 'stealing' and moving our contacts to their lists.
	private lazy var localContainer: String = {
		let store = CNContactStore()
		let defaultContainer = store.defaultContainerIdentifier()

		do {
			let containers = try store.containers(matching: nil)
			TUTSLog("Contact containers: \(containers.map { "\($0.name) \($0.type) \($0.type.rawValue)" }.joined(separator: ","))")

			// Apple allow just ONE local container, so we can query for the first and unique one
			let localContainer = containers.first(where: { $0.type == CNContainerType.local })

			return localContainer?.identifier ?? defaultContainer
		} catch {
			TUTSLog("Failed to get local container, using default")
			return defaultContainer
		}
	}()

	func getLocalContainer() -> String {
		return localContainer
	}

	func createCNGroup(username: String) throws -> CNMutableGroup {
		let newGroup = CNMutableGroup()
		newGroup.name = "Tuta \(username)"

		let saveRequest = CNSaveRequest()
		saveRequest.add(newGroup, toContainerWithIdentifier: localContainer)

		do { try CNContactStore().execute(saveRequest) } catch { throw ContactStoreError(message: "Could not create CNGroup", underlyingError: error) }

		return newGroup
	}

	func loadCNGroup(withIdentifier: String) throws -> CNGroup? {
		let store = CNContactStore()
		let groups = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [withIdentifier]))
		return groups.first
	}

	func deleteCNGroup(forGroup group: CNGroup) throws {
		// we now need to create a request to remove all contacts from the user that match an id in idsToRemove
		// it is OK if we are missing some contacts, as they are likely already deleted
		let store = CNContactStore()
		let fetch = self.makeContactFetchRequest(forKeys: [CNContactIdentifierKey] as [CNKeyDescriptor])

		fetch.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
		let save = CNSaveRequest()

		try self.enumerateContactsInContactStore(store, with: fetch) { contact, _ in save.delete(contact.mutableCopy() as! CNMutableContact) }

		try store.execute(save)

		// Delete the group itself
		let saveRequest = CNSaveRequest()
		saveRequest.delete(group.mutableCopy() as! CNMutableGroup)
		try store.execute(saveRequest)
	}

	func getAllContacts(inGroup group: CNGroup) throws -> [CNContact] {
		let store = CNContactStore()
		let fetch = makeContactFetchRequest()
		fetch.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)

		var contacts = [CNContact]()
		try self.enumerateContactsInContactStore(store, with: fetch) { contact, _ in contacts.append(contact) }

		return contacts
	}

	func insert(contacts: [NativeMutableContact], toGroup group: CNGroup) throws {
		let store = CNContactStore()
		let saveRequest = CNSaveRequest()

		for nativeContact in contacts {
				saveRequest.add(nativeContact.contact, toContainerWithIdentifier: localContainer)
				saveRequest.addMember(nativeContact.contact, to: group)
		}

		do { try store.execute(saveRequest) } catch { throw ContactStoreError(message: "Could not insert contacts", underlyingError: error) }
	}

	func update(contacts: [NativeMutableContact]) throws {
		let store = CNContactStore()
		let saveRequest = CNSaveRequest()

		for nativeMutableContact in contacts {
			saveRequest.update(nativeMutableContact.contact)
		}

		do { try store.execute(saveRequest) } catch { throw ContactStoreError(message: "Could not update contacts", underlyingError: error) }
	}

	func delete(localContacts nativeIdentifiersToRemove: [String]) throws {
		
		let store = CNContactStore()
		let fetch = makeContactFetchRequest(forKeys: [CNContactIdentifierKey] as [CNKeyDescriptor])

		fetch.predicate = CNContact.predicateForContacts(withIdentifiers: nativeIdentifiersToRemove)
		let save = CNSaveRequest()

		try self.enumerateContactsInContactStore(store, with: fetch) { contact, _ in save.delete(contact.mutableCopy() as! CNMutableContact) }

		try store.execute(save)
	}

	func enumerateContactsInContactStore(
		_ contactStore: CNContactStore,
		with fetchRequest: CNContactFetchRequest,
		usingBlock block: (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void
	) throws {
		do { try contactStore.enumerateContacts(with: fetchRequest, usingBlock: block) } catch {
			throw ContactStoreError(message: "Could not enumerate contacts", underlyingError: error)
		}
	}

	/// Create a fetch request that also loads data for a set of keys on each contact, ensuring that only real, non-unified contacts are pulled from the contact store.
	func makeContactFetchRequest(forKeys keysToFetch: [CNKeyDescriptor]) -> CNContactFetchRequest {
		var fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
		fetchRequest.unifyResults = false
		return fetchRequest
	}

	/// Create a fetch request that gets all supported keys, ensuring only real, non-unified contacts are pulled from the contact store.
	func makeContactFetchRequest() -> CNContactFetchRequest {
		makeContactFetchRequest(forKeys: ALL_SUPPORTED_CONTACT_KEYS)
	}
}

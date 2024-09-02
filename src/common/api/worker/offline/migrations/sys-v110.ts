import { OfflineMigration } from "../OfflineStorageMigrator.js"
import { OfflineStorage } from "../OfflineStorage.js"
import { addValue, migrateAllElements, removeValue } from "../StandardMigrations.js"
import { GroupTypeRef } from "../../../entities/sys/TypeRefs.js"

export const sys110: OfflineMigration = {
	app: "sys",
	version: 110,
	async migrate(storage: OfflineStorage) {
		await migrateAllElements(GroupTypeRef, storage, [removeValue("pubAdminGroupEncGKey"), addValue("pubAdminGroupEncGKey", null)])
	},
}

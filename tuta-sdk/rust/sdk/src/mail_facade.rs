use std::sync::Arc;

use crate::{ApiCallError, IdTuple, ListLoadDirection};
#[mockall_double::double]
use crate::crypto_entity_client::CryptoEntityClient;
use crate::entities::tutanota::{Mail, MailBox, MailboxGroupRoot, MailFolder};
use crate::generated_id::GeneratedId;
use crate::groups::GroupType;
use crate::user_facade::UserFacade;

/// Provides high level functions to manipulate mail entities via the REST API
#[derive(uniffi::Object)]
pub struct MailFacade {
	crypto_entity_client: Arc<CryptoEntityClient>,
	user_facade: Arc<UserFacade>,
}

impl MailFacade {
	pub fn new(crypto_entity_client: Arc<CryptoEntityClient>, user_facade: Arc<UserFacade>) -> Self {
		MailFacade {
			crypto_entity_client,
			user_facade,
		}
	}
}

impl MailFacade {
	pub async fn load_user_mailbox(&self) -> Result<MailBox, ApiCallError> {
		let user = self.user_facade.get_user();
		let mail_group_ship = user
			.memberships
			.iter()
			.find(|m| m.groupType == Some(GroupType::Mail.raw_value() as i64))
			.unwrap();
		let group_root: MailboxGroupRoot = self
			.crypto_entity_client
			.load(&mail_group_ship.group)
			.await?;
		let mailbox: MailBox = self.crypto_entity_client.load(&group_root.mailbox).await?;
		Ok(mailbox)
	}

	pub async fn load_folders_for_mailbox(&self, mailbox: &MailBox) -> Result<Vec<MailFolder>, ApiCallError> {
		let folders_list = &mailbox.folders.as_ref().unwrap().folders;
		let folders: Vec<MailFolder> = self.crypto_entity_client.load_range(folders_list, &GeneratedId::min_id(), 100, ListLoadDirection::ASC).await?;
		Ok(folders)
	}
}

#[uniffi::export]
impl MailFacade {
	/// Gets an email (an entity/instance of `Mail`) from the backend
	pub async fn load_email_by_id_encrypted(
		&self,
		id_tuple: &IdTuple,
	) -> Result<Mail, ApiCallError> {
		self.crypto_entity_client
			.load::<Mail, IdTuple>(id_tuple)
			.await
	}
}

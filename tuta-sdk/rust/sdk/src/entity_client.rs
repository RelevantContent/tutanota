use std::fmt::Display;
use std::sync::Arc;

use crate::element_value::{ElementValue, ParsedEntity};
use crate::generated_id::GeneratedId;
use crate::json_element::RawEntity;
use crate::json_serializer::JsonSerializer;
use crate::metamodel::{ElementType, TypeModel};
use crate::rest_client::{HttpMethod, RestClient, RestClientOptions};
use crate::rest_error::HttpError;
use crate::type_model_provider::TypeModelProvider;
use crate::{ApiCallError, HeadersProvider, IdTuple, ListLoadDirection, TypeRef};

/// Denotes an ID that can be serialised into a string and used to access resources
pub trait IdType: Display + 'static {}

/// A high level interface to manipulate unencrypted entities/instances via the REST API
pub struct EntityClient {
	rest_client: Arc<dyn RestClient>,
	base_url: String,
	auth_headers_provider: Arc<HeadersProvider>,
	json_serializer: Arc<JsonSerializer>,
	type_model_provider: Arc<TypeModelProvider>,
}

impl EntityClient {
	#[allow(dead_code)]
	pub(crate) fn new(
		rest_client: Arc<dyn RestClient>,
		json_serializer: Arc<JsonSerializer>,
		base_url: String,
		auth_headers_provider: Arc<HeadersProvider>,
		type_model_provider: Arc<TypeModelProvider>,
	) -> Self {
		EntityClient {
			rest_client,
			json_serializer,
			base_url,
			auth_headers_provider,
			type_model_provider,
		}
	}

	/// Gets an entity/instance of type `type_ref` from the backend
	pub async fn load<Id: IdType>(
		&self,
		type_ref: &TypeRef,
		id: &Id,
	) -> Result<ParsedEntity, ApiCallError> {
		let url = format!(
			"{}/rest/{}/{}/{}",
			self.base_url, type_ref.app, type_ref.type_, id
		);
		let response_bytes = self
			.prepare_and_fire(type_ref, url)
			.await?
			.expect("no body");
		let response_entity =
			serde_json::from_slice::<RawEntity>(response_bytes.as_slice()).unwrap();
		let parsed_entity = self.json_serializer.parse(type_ref, response_entity)?;
		Ok(parsed_entity)
	}

	/// Returns the definition of an entity/instance type using the internal `TypeModelProvider`
	pub fn get_type_model(&self, type_ref: &TypeRef) -> Result<&TypeModel, ApiCallError> {
		self.type_model_provider
			.get_type_model(type_ref.app, type_ref.type_)
			.ok_or_else(|| {
				let message = format!("Model {} not found in app {}", type_ref.type_, type_ref.app);
				ApiCallError::InternalSdkError {
					error_message: message,
				}
			})
	}

	/// Fetches and returns all entities/instances in a list element type
	#[allow(clippy::unused_async)]
	pub async fn load_all(
		&self,
		_type_ref: &TypeRef,
		_list_id: &IdTuple,
		_start: Option<String>,
	) -> Result<Vec<ParsedEntity>, ApiCallError> {
		todo!("entity client load_all")
	}

	/// Fetches and returns a specified number (`count`) of entities/instances
	/// in a list element type starting at the index `start_id`
	#[allow(clippy::unused_async)]
	pub async fn load_range(
		&self,
		type_ref: &TypeRef,
		list_id: &GeneratedId,
		start_id: &GeneratedId,
		count: usize,
		direction: ListLoadDirection,
	) -> Result<Vec<ParsedEntity>, ApiCallError> {
		let type_model = self.get_type_model(type_ref)?;
		assert_eq!(type_model.element_type, ElementType::ListElement, "cannot load range for non-list element");
		// FIXME: validate parameters
		let reverse = direction == ListLoadDirection::DESC;
		// TODO: this is not the best way to build URL, we assume that everything is URL safe
		// TODO: custom ids? are they fine?
		let url = format!(
			"{}/rest/{}/{}/{}?start={start_id}&count={count}&reverse={reverse}",
			self.base_url, type_ref.app, type_ref.type_, list_id
		);
		let response_bytes = self
			.prepare_and_fire(type_ref, url)
			.await?
			.expect("no body");
		let response_entities = serde_json::from_slice::<Vec<RawEntity>>(response_bytes.as_slice())
			.expect("invalid response");
		let parsed_entities = response_entities
			.into_iter()
			.map(|e| self.json_serializer.parse(type_ref, e))
			.collect::<Result<Vec<_>, _>>()?;
		Ok(parsed_entities)
	}

	/// Stores a newly created entity/instance as a single element on the backend
	#[allow(clippy::unused_async)]
	pub async fn setup_element(&self, _type_ref: &TypeRef, _entity: RawEntity) -> Vec<String> {
		todo!("entity client setup_element")
	}

	/// Stores a newly created entity/instance as a part of a list element on the backend
	#[allow(clippy::unused_async)]
	pub async fn setup_list_element(
		&self,
		_type_ref: &TypeRef,
		_list_id: &IdTuple,
		_entity: RawEntity,
	) -> Vec<String> {
		todo!("entity client setup_list_element")
	}

	/// Updates an entity/instance in the backend
	pub async fn update(
		&self,
		type_ref: &TypeRef,
		entity: ParsedEntity,
		model_version: u32,
	) -> Result<(), ApiCallError> {
		let id = match &entity.get("_id").unwrap() {
			ElementValue::IdTupleId(ref id_tuple) => id_tuple.to_string(),
			_ => panic!("id is not string or array"),
		};
		let raw_entity = self.json_serializer.serialize(type_ref, entity)?;
		let body = serde_json::to_vec(&raw_entity).unwrap();
		let options = RestClientOptions {
			body: Some(body),
			headers: self.auth_headers_provider.provide_headers(model_version),
		};
		// FIXME we should look at type model whether it is ET or LET
		let url = format!(
			"{}/rest/{}/{}/{}",
			self.base_url, type_ref.app, type_ref.type_, id
		);
		self.rest_client
			.request_binary(url, HttpMethod::PUT, options)
			.await?;
		Ok(())
	}

	/// Deletes an existing single entity/instance on the backend
	#[allow(clippy::unused_async)]
	pub async fn erase_element(
		&self,
		_type_ref: &TypeRef,
		_id: &GeneratedId,
	) -> Result<(), ApiCallError> {
		todo!("entity client erase_element")
	}

	/// Deletes an existing entity/instance of a list element type on the backend
	#[allow(clippy::unused_async)]
	pub async fn erase_list_element(
		&self,
		_type_ref: &TypeRef,
		_id: IdTuple,
	) -> Result<(), ApiCallError> {
		todo!("entity client erase_list_element")
	}

	async fn prepare_and_fire(
		&self,
		type_ref: &TypeRef,
		url: String,
	) -> Result<Option<Vec<u8>>, ApiCallError> {
		let type_model = self.get_type_model(type_ref)?;
		let model_version: u32 = type_model.version.parse().expect("invalid model_version");
		let options = RestClientOptions {
			body: None,
			headers: self.auth_headers_provider.provide_headers(model_version),
		};
		let response = self
			.rest_client
			.request_binary(url, HttpMethod::GET, options)
			.await?;
		let precondition = response.headers.get("precondition");
		match response.status {
			200..=299 => {
				// Ok
			},
			_ => {
				return Err(ApiCallError::ServerResponseError {
					source: HttpError::from_http_response(response.status, precondition)?,
				})
			},
		}
		Ok(response.body)
	}
}

#[cfg(test)]
mockall::mock! {
	pub EntityClient {
		pub fn new(
			rest_client: Arc<dyn RestClient>,
			json_serializer: Arc<JsonSerializer>,
			base_url: String,
			auth_headers_provider: Arc<HeadersProvider>,
			type_model_provider: Arc<TypeModelProvider>,
		) -> Self;
		pub fn get_type_model(&self, type_ref: &TypeRef) -> Result<&'static TypeModel, ApiCallError>;
		pub async fn load<Id: IdType>(
			&self,
			type_ref: &TypeRef,
			id: &Id,
		 ) -> Result<ParsedEntity, ApiCallError>;
		pub async fn load_all(
			&self,
			type_ref: &TypeRef,
			list_id: &IdTuple,
			start: Option<String>,
		) -> Result<Vec<ParsedEntity>, ApiCallError>;
		pub async fn load_range(
			&self,
			type_ref: &TypeRef,
			list_id: &GeneratedId,
			start_id: &GeneratedId,
			count: usize,
			list_load_direction: ListLoadDirection,
		) -> Result<Vec<ParsedEntity>, ApiCallError>;
		pub async fn setup_element(&self, type_ref: &TypeRef, entity: RawEntity) -> Vec<String>;
		pub async fn setup_list_element(
			&self,
			type_ref: &TypeRef,
			list_id: &IdTuple,
			entity: RawEntity,
		) -> Vec<String>;
		pub async fn update(&self, type_ref: &TypeRef, entity: ParsedEntity, model_version: u32)
						-> Result<(), ApiCallError>;
		pub async fn erase_element(&self, type_ref: &TypeRef, id: &GeneratedId) -> Result<(), ApiCallError>;
		pub async fn erase_list_element(&self, type_ref: &TypeRef, id: IdTuple) -> Result<(), ApiCallError>;
	}
}

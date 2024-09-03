use std::sync::Arc;
use reqwest::Method;
use tutasdk::generated_id::GeneratedId;
use tutasdk::login::{Credentials, CredentialType};
use tutasdk::rest_client::{
	HttpMethod, RestClient, RestClientError, RestClientOptions, RestResponse,
};
use tutasdk::Sdk;

struct ReqwestHttpClient {
	client: reqwest::Client,
}

impl RestClient for ReqwestHttpClient {
	async fn request_binary(
		&self,
		url: String,
		method: HttpMethod,
		options: RestClientOptions,
	) -> Result<RestResponse, RestClientError> {
		self.request_inner(url, method, options).await
			.map_err(|e| {
				eprintln!("Network request failed! {:?}", e);
				RestClientError::NetworkError
			})
	}
}

impl ReqwestHttpClient {
	fn new() -> Self {
		ReqwestHttpClient { client: reqwest::Client::new() }
	}
	async fn request_inner(&self, url: String, method: HttpMethod, options: RestClientOptions) -> Result<RestResponse, reqwest::Error> {
		let mut req = self.client.request(
			http_method(method),
			url
		);
		if let Some(body) = options.body {
			req = req.body(body)?;
		}
		let res = req.headers(options.headers.into())
			.send()
			.await?;

		Ok(RestResponse {
			status: res.status().as_u16() as u32,
			headers: res.headers().into(),
			body: res.bytes().into(),
		})
	}
}

fn http_method(http_method: HttpMethod) -> reqwest::Method {
	use reqwest::Method;
	match http_method {
		HttpMethod::GET => Method::GET,
		HttpMethod::POST => Method::POST,
		HttpMethod::PUT => Method::PUT,
		HttpMethod::DELETE => Method::DELETE,
	}
}

#[tokio::main]
async fn main() -> Result<(), dyn std::error::Error> {
	let rest_client = (ReqwestHttpClient::new());
	let sdk = Sdk::new(
		"http://localhost:9000".to_owned(),
		Arc::new(rest_client),
		"244.0.0".to_owned(),
	);
	let credentials = Credentials {
		login: "bed-free@tutanota.de".to_owned(),
		access_token: "123".to_owned(),
		credential_type: CredentialType::Internal,
		user_id: GeneratedId("123".to_owned()),
		encrypted_passphrase_key: vec![],
	}
	sdk.login()
}

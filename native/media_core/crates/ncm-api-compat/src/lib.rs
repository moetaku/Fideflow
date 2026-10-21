//! Fideflow Host compatibility boundary for the unmodified NCM SDK.
#![deny(unsafe_code)]
pub use ncm_api_rs::{crypto, util};
pub mod api;
pub mod error;
pub mod request;
pub use api::Query;
pub use error::NcmError;
pub use request::{ApiClient, ApiResponse, CryptoType, RequestOption};

//! In-process NCM adapter. No dependency from the generic playback crates.
use fideflow_ncm_api_compat::{ApiClient, ApiResponse, NcmError, Query};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
use tokio::{runtime::Runtime, task::AbortHandle};

pub type EventSink = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub request_id: String,
    pub account_epoch: u64,
    pub route: String,
    pub params: HashMap<String, String>,
    pub cookie: Option<String>,
    pub device_id: String,
    pub budget_ms: u64,
    pub max_response_bytes: usize,
}

impl Request {
    #[must_use]
    pub fn from_json(document: &str) -> Option<Self> {
        let request: Self = serde_json::from_str(document).ok()?;
        if request.request_id.is_empty()
            || request.request_id.len() > 128
            || !(1..=15_000).contains(&request.budget_ms)
            || !(1..=16 * 1024 * 1024).contains(&request.max_response_bytes)
            || request.device_id.len() != 52
            || !request
                .device_id
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'A'..=b'F').contains(&c))
            || request.params.contains_key("cookie")
            || request.params.contains_key("proxy")
            || request.params.contains_key("domain")
        {
            return None;
        }
        Some(request)
    }
}

struct Inner {
    tasks: Mutex<HashMap<String, AbortHandle>>,
    sink: Mutex<Option<EventSink>>,
    published: AtomicU64,
}

pub struct Host {
    runtime: Option<Runtime>,
    client: ApiClient,
    inner: Arc<Inner>,
}

impl Host {
    /// Initialization can fail without unwinding into the embedding host.
    /// # Errors
    /// Returns a sanitized code if the runtime or HTTP pool cannot initialize.
    pub fn new() -> Result<Self, &'static str> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("ncm-host")
            .build()
            .map_err(|_| "ncmHost.initializationFailed")?;
        let client = {
            let _entered = runtime.enter();
            ApiClient::try_new().map_err(|_| "ncmHost.initializationFailed")?
        };
        Ok(Self {
            runtime: Some(runtime),
            client,
            inner: Arc::new(Inner {
                tasks: Mutex::new(HashMap::new()),
                sink: Mutex::new(None),
                published: AtomicU64::new(0),
            }),
        })
    }

    /// Clearing waits for an in-progress callback. Callbacks must not reenter.
    pub fn set_event_sink(&self, sink: Option<EventSink>) {
        *self
            .inner
            .sink
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = sink;
    }

    /// Duplicate active IDs and an exhausted queue are rejected synchronously.
    pub fn submit(&self, request: Request) -> bool {
        let mut tasks = self
            .inner
            .tasks
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if tasks.contains_key(&request.request_id) || tasks.len() >= 64 {
            return false;
        }
        let client = self
            .client
            .clone()
            .with_response_limit(request.max_response_bytes);
        let inner = Arc::clone(&self.inner);
        let id = request.request_id.clone();
        let Some(runtime) = self.runtime.as_ref() else {
            return false;
        };
        let task = runtime.spawn(async move {
            let result = tokio::time::timeout(
                Duration::from_millis(request.budget_ms),
                execute(client, &request),
            )
            .await;
            let mut event = match result {
                Ok(Ok(response)) => {
                    let mut bound = BodyBound(request.max_response_bytes);
                    if serde_json::to_writer(&mut bound, &response.body).is_err() {
                        json!({"error":"ncm.responseTooLarge"})
                    } else {
                        json!({"status":response.status, "body":response.body,
                            "setCookie":response.cookie, "serverTime":response.server_time})
                    }
                }
                Ok(Err(error)) => error_result(error),
                Err(_) => json!({"error":"network.timeout"}),
            };
            event["schemaVersion"] = json!(1);
            event["requestId"] = json!(request.request_id);
            event["accountEpoch"] = json!(request.account_epoch);
            // Removing and publishing share the registry lock with cancellation.
            // Whichever wins owns the sole completion for this request.
            let mut tasks = inner
                .tasks
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if tasks.remove(&request.request_id).is_some()
                && let Some(sink) = inner
                    .sink
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .as_ref()
            {
                inner.published.fetch_add(1, Ordering::Relaxed);
                sink(&event.to_string());
            }
        });
        tasks.insert(id, task.abort_handle());
        true
    }

    /// Number of callbacks posted. Read after clearing the sink for a drain barrier.
    #[must_use]
    pub fn deliveries(&self) -> u64 {
        self.inner.published.load(Ordering::Relaxed)
    }

    pub fn cancel(&self, id: &str) {
        if let Some(task) = self
            .inner
            .tasks
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(id)
        {
            task.abort();
        }
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        self.set_event_sink(None);
        for (_, task) in self
            .inner
            .tasks
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .drain()
        {
            task.abort();
        }
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_timeout(Duration::from_secs(1));
        }
    }
}

struct BodyBound(usize);
impl std::io::Write for BodyBound {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > self.0 {
            return Err(std::io::Error::other("response bound"));
        }
        self.0 -= bytes.len();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

// Inspect every source: reqwest's outer `request` error often wraps the useful
// hyper/rustls/socket cause. Emit only known labels, never arbitrary error text.
fn network_causes(error: &(dyn std::error::Error + 'static)) -> Vec<&'static str> {
    let mut causes = Vec::new();
    let mut current = Some(error);
    for _ in 0..12 {
        let Some(source) = current else { break };
        let message = source.to_string().to_ascii_lowercase();
        for (needle, label) in [
            ("dns", "dns"),
            ("name resolution", "dns"),
            ("certificate", "tlsCertificate"),
            ("tls", "tls"),
            ("handshake", "handshake"),
            ("http2", "http2"),
            ("http/2", "http2"),
            ("goaway", "http2Goaway"),
            ("reset", "reset"),
            ("broken pipe", "brokenPipe"),
            ("connection closed", "connectionClosed"),
            ("incomplete message", "incompleteMessage"),
            ("unexpected eof", "unexpectedEof"),
            ("connection refused", "connectionRefused"),
            ("network is unreachable", "networkUnreachable"),
            ("timed out", "timeout"),
            ("invalid peer", "tlsPeer"),
            ("invalid header", "invalidHeader"),
            ("invalid url", "invalidUrl"),
            ("canceled", "cancelled"),
        ] {
            if message.contains(needle) && !causes.contains(&label) {
                causes.push(label);
            }
        }
        if let Some(io) = source.downcast_ref::<std::io::Error>() {
            let label = match io.kind() {
                std::io::ErrorKind::ConnectionReset => "reset",
                std::io::ErrorKind::ConnectionAborted => "connectionAborted",
                std::io::ErrorKind::ConnectionRefused => "connectionRefused",
                std::io::ErrorKind::TimedOut => "timeout",
                std::io::ErrorKind::UnexpectedEof => "unexpectedEof",
                std::io::ErrorKind::BrokenPipe => "brokenPipe",
                std::io::ErrorKind::NotConnected => "notConnected",
                std::io::ErrorKind::PermissionDenied => "permissionDenied",
                _ => "ioOther",
            };
            if !causes.contains(&label) {
                causes.push(label);
            }
        }
        current = source.source();
    }
    if causes.is_empty() {
        causes.push("unclassified");
    }
    causes
}

fn error_result(error: NcmError) -> Value {
    // No upstream exception text, private response, URL or cookie crosses diagnostics.
    match error {
        NcmError::AuthRequired(_) => json!({"status":401,"body":{"code":301},"setCookie":[]}),
        NcmError::InvalidParam(_) => json!({"status":400,"body":{"code":400},"setCookie":[]}),
        NcmError::RateLimited(_) => json!({"status":429,"body":{"code":503},"setCookie":[]}),
        NcmError::Api { code, .. } => json!({"status":code,"body":{"code":code},"setCookie":[]}),
        NcmError::Timeout(_) => json!({"error":"network.timeout"}),
        NcmError::Http(error) => {
            // Only allowlisted classifications cross FFI, never reqwest's URL/error text.
            let reason = if error.is_timeout() {
                "timeout"
            } else if error.is_connect() {
                "connect"
            } else if error.is_body() {
                "body"
            } else if error.is_decode() {
                "decode"
            } else if error.is_request() {
                "request"
            } else {
                "transport"
            };
            json!({"error":if error.is_timeout() {"network.timeout"} else {"network.unreachable"},
                "networkReason":reason, "networkCauses":network_causes(&error)})
        }
        NcmError::ResponseTooLarge => json!({"error":"ncm.responseTooLarge"}),
        NcmError::Json(_) | NcmError::Crypto(_) => json!({"error":"provider.schemaChanged"}),
        NcmError::Unknown(_) => json!({"error":"ncm.upstreamError"}),
    }
}

macro_rules! routes {
    ($($route:literal => $method:ident),* $(,)?) => {
        pub const ROUTES: &[&str] = &[$($route),*];
        async fn dispatch(client: &ApiClient, route: &str, query: &Query) -> fideflow_ncm_api_compat::error::Result<ApiResponse> {
            match route {
                $($route => client.$method(query).await,)*
                _ => Err(NcmError::InvalidParam("unsupported route".into())),
            }
        }
    }
}

routes! {
    "/album" => album,
    "/album/sub" => album_sub,
    "/album/sublist" => album_sublist,
    "/artists" => artists,
    "/cloudsearch" => cloudsearch,
    "/like" => like,
    "/likelist" => likelist,
    "/login/qr/check" => login_qr_check,
    "/login/qr/create" => login_qr_create,
    "/login/qr/key" => login_qr_key,
    "/login/cellphone" => login_cellphone,
    "/captcha/sent" => captcha_sent,
    "/deviceinfo/center/upload" => deviceinfo_center_upload,
    "/logout" => logout,
    "/lyric" => lyric,
    "/lyric/new" => lyric_new,
    "/personalized" => personalized,
    "/personalized/newsong" => personalized_newsong,
    "/playlist/catlist" => playlist_catlist,
    "/playlist/create" => playlist_create,
    "/playlist/delete" => playlist_delete,
    "/playlist/desc/update" => playlist_desc_update,
    "/playlist/detail" => playlist_detail,
    "/playlist/hot" => playlist_hot,
    "/playlist/name/update" => playlist_name_update,
    "/playlist/subscribe" => playlist_subscribe,
    "/playlist/tags/update" => playlist_tags_update,
    "/playlist/track/all" => playlist_track_all,
    "/playlist/tracks" => playlist_tracks,
    "/playmode/intelligence/list" => playmode_intelligence_list,
    "/recent/listen/list" => recent_listen_list,
    "/recommend/resource" => recommend_resource,
    "/recommend/songs" => recommend_songs,
    "/record/recent/playlist" => record_recent_playlist,
    "/song/detail" => song_detail,
    "/song/order/update" => song_order_update,
    "/song/url/v1" => song_url_v1,
    "/top/playlist" => top_playlist,
    "/top/playlist/highquality" => top_playlist_highquality,
    "/toplist" => toplist,
    "/user/account" => user_account,
    "/user/playlist" => user_playlist,
    "/vip/info/v2" => vip_info_v2,
}

async fn execute(
    mut client: ApiClient,
    request: &Request,
) -> fideflow_ncm_api_compat::error::Result<ApiResponse> {
    client.set_device_id(request.device_id.clone());
    let cookie = format!(
        "{}; deviceId={}",
        request.cookie.as_deref().unwrap_or(""),
        request.device_id
    );
    let mut query = Query::new().cookie(&cookie);
    query.params.clone_from(&request.params);
    dispatch(&client, &request.route, &query).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        sync::mpsc,
        thread,
    };

    fn request(id: &str, route: &str) -> Request {
        Request::from_json(
            &json!({"requestId":id,"accountEpoch":7,"route":route,
            "params":{"key":"test-key"},"cookie":null,"deviceId":"A".repeat(52),
            "budgetMs":15000,"maxResponseBytes":1024})
            .to_string(),
        )
        .unwrap()
    }

    #[test]
    fn route_table_covers_the_gateway_and_remains_a_leaf() {
        let dart =
            include_str!("../../../../../packages/ncm_gateway/lib/src/remote_ncm_provider.dart");
        for token in dart
            .split('\'')
            .filter(|s| s.starts_with('/') && s.len() > 1 && !s.contains(char::is_whitespace))
        {
            assert!(ROUTES.contains(&token), "unmapped gateway route: {token}");
        }
        let manifest = include_str!("../../media-session/Cargo.toml");
        assert!(!manifest.contains("ncm"));
    }

    #[test]
    fn validates_identity_budgets_and_disallows_shared_cookie_parameters() {
        let mut document: Value = serde_json::from_str(
            &json!({"requestId":"1","accountEpoch":0,
            "route":"/song/detail","params":{},"cookie":null,"deviceId":"A".repeat(52),
            "budgetMs":15000,"maxResponseBytes":1024})
            .to_string(),
        )
        .unwrap();
        for (key, value) in [
            ("deviceId", json!("a".repeat(52))),
            ("budgetMs", json!(15001)),
            ("maxResponseBytes", json!(0)),
            ("params", json!({"cookie":"MUSIC_U=secret"})),
        ] {
            let old = document[key].take();
            document[key] = value;
            assert!(Request::from_json(&document.to_string()).is_none());
            document[key] = old;
        }
    }

    #[test]
    fn correlates_completions_and_sink_clear_is_a_delivery_barrier() {
        let host = Host::new().unwrap();
        let (tx, rx) = mpsc::channel();
        host.set_event_sink(Some(Arc::new(move |s| {
            tx.send(s.to_owned()).unwrap();
        })));
        for id in ["1", "2"] {
            assert!(host.submit(request(id, "/login/qr/create")));
        }
        let mut ids = Vec::new();
        for _ in 0..2 {
            let event: Value =
                serde_json::from_str(&rx.recv_timeout(Duration::from_secs(2)).unwrap()).unwrap();
            assert_eq!(event["accountEpoch"], 7);
            assert_eq!(event["status"], 200);
            ids.push(event["requestId"].as_str().unwrap().to_owned());
        }
        ids.sort();
        assert_eq!(ids, ["1", "2"]);
        host.set_event_sink(None);
        assert_eq!(host.deliveries(), 2);
        assert!(host.submit(request("3", "/login/qr/create")));
        drop(host);
        assert!(rx.recv_timeout(Duration::from_millis(30)).is_err());
    }

    #[test]
    fn duplicate_ids_cancel_and_free_abort_work_without_network() {
        let host = Host::new().unwrap();
        let task = host
            .runtime
            .as_ref()
            .unwrap()
            .spawn(std::future::pending::<()>());
        host.inner
            .tasks
            .lock()
            .unwrap()
            .insert("duplicate".into(), task.abort_handle());
        assert!(!host.submit(request("duplicate", "/login/qr/create")));
        host.cancel("duplicate");
        assert!(host.inner.tasks.lock().unwrap().is_empty());
        assert!(host.submit(request("duplicate", "/login/qr/create")));
        drop(host);
    }

    #[test]
    fn network_diagnostics_inspect_sources_without_exposing_messages() {
        #[derive(Debug)]
        struct Wrapped(std::io::Error);
        impl std::fmt::Display for Wrapped {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("request failed at https://private-url?cookie=secret")
            }
        }
        impl std::error::Error for Wrapped {
            fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
                Some(&self.0)
            }
        }
        let error = Wrapped(std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "private-response",
        ));
        assert_eq!(network_causes(&error), vec!["reset"]);
        let text = serde_json::to_string(&network_causes(&error)).unwrap();
        assert!(!text.contains("private"));
        assert!(!text.contains("secret"));
        assert_eq!(
            network_causes(&std::io::Error::other("HTTP/2 GOAWAY: private")),
            vec!["http2", "http2Goaway", "ioOther"],
        );
    }

    #[test]
    fn error_diagnostics_never_contain_private_payloads() {
        for error in [
            NcmError::AuthRequired("private-cookie".into()),
            NcmError::Unknown("https://private-url?key=secret".into()),
            NcmError::RateLimited("private-response".into()),
        ] {
            let text = error_result(error).to_string();
            assert!(!text.contains("private"));
            assert!(!text.contains("secret"));
        }
    }

    fn sdk_response(
        body: &'static str,
        limit: usize,
    ) -> fideflow_ncm_api_compat::error::Result<ApiResponse> {
        sdk_response_at(body, limit, "/api/test")
    }

    fn sdk_response_at(
        body: &'static str,
        limit: usize,
        uri: &str,
    ) -> fideflow_ncm_api_compat::error::Result<ApiResponse> {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut bytes = [0; 8192];
            let _ = stream.read(&mut bytes);
            let reply = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nDate: Sun, 18 Oct 2026 00:00:00 GMT\r\nSet-Cookie: MUSIC_U=fixture; HttpOnly\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = stream.write_all(reply.as_bytes());
        });
        let runtime = tokio::runtime::Runtime::new().unwrap();
        let result = runtime.block_on(async {
            ApiClient::try_new()
                .unwrap()
                .with_response_limit(limit)
                .request(
                    uri,
                    json!({}),
                    fideflow_ncm_api_compat::RequestOption {
                        crypto: fideflow_ncm_api_compat::CryptoType::Api,
                        domain: Some(format!("http://{address}")),
                        ..Default::default()
                    },
                )
                .await
        });
        server.join().unwrap();
        result
    }

    #[test]
    fn sms_business_errors_keep_their_bounded_body() {
        for uri in ["/api/w/login/cellphone", "/api/sms/captcha/sent"] {
            let response =
                sdk_response_at(r#"{"code":503,"msg":"验证码错误"}"#, 1024, uri).unwrap();
            assert_eq!(response.status, 503);
            assert_eq!(response.body["msg"], "验证码错误");
            assert!(matches!(
                sdk_response_at(r#"{"code":503,"msg":"oversized"}"#, 8, uri),
                Err(NcmError::ResponseTooLarge)
            ));
        }
    }

    #[test]
    fn device_name_route_uses_eapi_and_the_request_device_identity() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut request = Vec::new();
            let mut chunk = [0; 8192];
            loop {
                let count = stream.read(&mut chunk).unwrap();
                assert!(count > 0);
                request.extend_from_slice(&chunk[..count]);
                let text = String::from_utf8_lossy(&request);
                if let Some(header_end) = text.find("\r\n\r\n") {
                    let length: usize = text[..header_end]
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse().unwrap())
                        })
                        .unwrap();
                    if request.len() >= header_end + 4 + length {
                        break;
                    }
                }
            }
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"code\":200}").unwrap();
            String::from_utf8(request).unwrap()
        });
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let client = ApiClient::try_new().unwrap();
            let mut query = Query::new()
                .cookie(&format!("MUSIC_U=fixture; deviceId={}", "A".repeat(52)))
                .param("deviceName", " 我的 Mac & PC ");
            query.domain = Some(format!("http://{address}"));
            assert_eq!(
                client.deviceinfo_center_upload(&query).await.unwrap().body["code"],
                200
            );
            query.params.insert("deviceName".into(), " ".into());
            assert!(matches!(
                client.deviceinfo_center_upload(&query).await,
                Err(NcmError::InvalidParam(_))
            ));
        });
        let request = server.join().unwrap();
        assert!(request.starts_with("POST /eapi/deviceinfo/center/upload "));
        let encrypted = request
            .split("\r\n\r\n")
            .nth(1)
            .unwrap()
            .strip_prefix("params=")
            .unwrap();
        let (path, payload) = fideflow_ncm_api_compat::crypto::eapi_req_decrypt(encrypted).unwrap();
        assert_eq!(path, "/api/deviceinfo/center/upload");
        assert_eq!(payload["deviceName"], "我的 Mac & PC");
        assert_eq!(payload["header"]["deviceId"], "A".repeat(52));
        assert_eq!(payload["header"]["MUSIC_U"], "fixture");
    }

    #[test]
    fn sdk_preserves_qr_status_cookies_and_date_and_bounds_streamed_responses() {
        for code in [801, 802, 803] {
            let body = match code {
                801 => "{\"code\":801}",
                802 => "{\"code\":802}",
                _ => "{\"code\":803}",
            };
            let response = sdk_response(body, 1024).unwrap();
            assert_eq!(response.status, 200);
            assert_eq!(response.body["code"], code);
            assert_eq!(response.cookie, ["MUSIC_U=fixture; HttpOnly"]);
            assert!(response.server_time.is_some());
        }
        assert!(matches!(
            sdk_response("{\"code\":200,\"data\":\"oversized\"}", 8),
            Err(NcmError::ResponseTooLarge)
        ));
    }
}

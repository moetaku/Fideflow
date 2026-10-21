use crate::request::{CheckToken, CryptoType, RequestOption};
use std::collections::HashMap;

#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/album.rs"]
mod album;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/album_sub.rs"]
mod album_sub;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/album_sublist.rs"]
mod album_sublist;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/artists.rs"]
mod artists;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/cloudsearch.rs"]
mod cloudsearch;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/like.rs"]
mod like;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/likelist.rs"]
mod likelist;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/login_qr_check.rs"]
mod login_qr_check;
mod login_cellphone;
mod login_qr_create;
mod login_qr_key;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/captcha_sent.rs"]
mod captcha_sent;
mod deviceinfo_center_upload;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/logout.rs"]
mod logout;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/lyric.rs"]
mod lyric;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/lyric_new.rs"]
mod lyric_new;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/personalized.rs"]
mod personalized;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/personalized_newsong.rs"]
mod personalized_newsong;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_catlist.rs"]
mod playlist_catlist;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_create.rs"]
mod playlist_create;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_delete.rs"]
mod playlist_delete;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_desc_update.rs"]
mod playlist_desc_update;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_detail.rs"]
mod playlist_detail;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_hot.rs"]
mod playlist_hot;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_name_update.rs"]
mod playlist_name_update;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_subscribe.rs"]
mod playlist_subscribe;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_tags_update.rs"]
mod playlist_tags_update;
mod playlist_track_all;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playlist_tracks.rs"]
mod playlist_tracks;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/playmode_intelligence_list.rs"]
mod playmode_intelligence_list;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/recent_listen_list.rs"]
mod recent_listen_list;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/recommend_resource.rs"]
mod recommend_resource;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/recommend_songs.rs"]
mod recommend_songs;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/record_recent_playlist.rs"]
mod record_recent_playlist;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/song_detail.rs"]
mod song_detail;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/song_order_update.rs"]
mod song_order_update;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/song_url_v1.rs"]
mod song_url_v1;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/top_playlist.rs"]
mod top_playlist;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/top_playlist_highquality.rs"]
mod top_playlist_highquality;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/toplist.rs"]
mod toplist;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/user_account.rs"]
mod user_account;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/user_playlist.rs"]
mod user_playlist;
#[rustfmt::skip]
#[path = "../../../../vendor/ncm-api-rs/src/api/vip_info_v2.rs"]
mod vip_info_v2;

/// 通用查询参数，用于向 API 方法传递参数
#[derive(Debug, Clone, Default)]
pub struct Query {
    pub params: HashMap<String, String>,
    pub cookie: Option<String>,
    pub proxy: Option<String>,
    pub real_ip: Option<String>,
    pub random_cn_ip: bool,
    pub ua: Option<String>,
    pub e_r: Option<bool>,
    pub domain: Option<String>,
    /// 额外请求头
    pub headers: HashMap<String, String>,
    /// 请求超时（毫秒）
    pub timeout: Option<u64>,
}

/// 环境变量 ENABLE_RANDOM_CN_IP=true 时，randomCNIP 默认开启（显式传 false 可关闭）
static ENABLE_RANDOM_CN_IP: std::sync::LazyLock<bool> =
    std::sync::LazyLock::new(|| std::env::var("ENABLE_RANDOM_CN_IP").as_deref() == Ok("true"));

impl Query {
    pub fn new() -> Self {
        Self::default()
    }

    /// 设置参数
    pub fn param(mut self, key: &str, value: &str) -> Self {
        self.params.insert(key.to_string(), value.to_string());
        self
    }

    /// 设置 cookie
    pub fn cookie(mut self, cookie: &str) -> Self {
        self.cookie = Some(cookie.to_string());
        self
    }

    /// 获取参数值
    pub fn get(&self, key: &str) -> Option<&str> {
        self.params.get(key).map(|s| s.as_str())
    }

    /// 获取参数值，若不存在则返回默认值
    pub fn get_or(&self, key: &str, default: &str) -> String {
        self.params
            .get(key)
            .cloned()
            .unwrap_or_else(|| default.to_string())
    }

    /// 获取 i64 参数，解析失败返回默认值
    ///
    /// 替代 `query.get_or("limit", "30").parse::<i64>().unwrap_or(30)` 模式
    pub fn get_i64(&self, key: &str, default: i64) -> i64 {
        match self.params.get(key) {
            Some(v) => v.parse::<i64>().unwrap_or(default),
            None => default,
        }
    }

    /// 获取 bool 参数（接受 "true"/"false"/"1"/"0"）
    ///
    /// 替代 `query.get_or("like", "true") == "true"` 模式
    pub fn get_bool(&self, key: &str, default: bool) -> bool {
        match self.params.get(key).map(|s| s.as_str()) {
            Some("true") | Some("1") => true,
            Some("false") | Some("0") => false,
            _ => default,
        }
    }

    /// 构造带反作弊 token 的 RequestOption
    pub(crate) fn to_option_token(
        &self,
        crypto: CryptoType,
        check_token: CheckToken,
    ) -> RequestOption {
        RequestOption {
            check_token,
            ..self.to_option(crypto)
        }
    }

    /// 覆盖 cookie 中的若干字段（如强制 os=android）
    pub(crate) fn with_cookie(&self, overrides: &[(&str, &str)]) -> Query {
        let mut map = crate::util::cookie::cookie_to_json(self.cookie.as_deref().unwrap_or(""));
        for (k, v) in overrides {
            map.insert(k.to_string(), v.to_string());
        }
        let mut q = self.clone();
        q.cookie = Some(crate::util::cookie::cookie_obj_to_string(&map));
        q
    }

    /// 构造 RequestOption
    ///
    /// 与 Node.js 版一致，参数 `crypto` 可覆盖接口默认的加密方式
    pub(crate) fn to_option(&self, crypto: CryptoType) -> RequestOption {
        RequestOption {
            crypto: self
                .get("crypto")
                .filter(|s| !s.is_empty())
                .map(CryptoType::from)
                .unwrap_or(crypto),
            cookie: self.cookie.clone(),
            ua: self.ua.clone(),
            proxy: self.proxy.clone(),
            real_ip: self.real_ip.clone(),
            random_cn_ip: self.random_cn_ip
                || (*ENABLE_RANDOM_CN_IP && self.get("randomCNIP") != Some("false")),
            e_r: self.e_r,
            domain: self.domain.clone(),
            check_token: CheckToken::None,
            headers: self.headers.clone(),
            timeout: self.timeout,
        }
    }
}

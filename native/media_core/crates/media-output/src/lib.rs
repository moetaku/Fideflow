//! `PortAudio` output with Core Audio, WASAPI or ALSA device policy.
//! PCM stays native. All control calls are serialized; render is lock-free.
use std::{
    ffi::{CString, c_char, c_int, c_uint, c_void},
    fmt,
    ptr::NonNull,
    sync::Mutex,
};
static CONTROL: Mutex<()> = Mutex::new(());

fn reject_unsupported_exclusive(config: &OutputConfiguration) -> Result<(), OutputError> {
    if cfg!(target_os = "linux")
        && config.exclusive
        && !config
            .device_uid
            .as_deref()
            .is_some_and(|uid| uid.starts_with("alsa:hw:"))
    {
        return Err(OutputError::DeviceOpen("outputExclusiveUnavailable".into()));
    }
    Ok(())
}

fn validate_negotiated_rate(rate: u32, exclusive: bool) -> Result<u32, OutputError> {
    let rate = if !exclusive && rate < 44_100 {
        48_000
    } else {
        rate
    };
    if !(8000..=384_000).contains(&rate) {
        return Err(OutputError::DeviceOpen("outputDeviceUnavailable".into()));
    }
    Ok(rate)
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum OutputError {
    Unavailable,
    DeviceEnumeration,
    DeviceOpen(String),
}
impl fmt::Display for OutputError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for OutputError {}
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PlaybackDevice {
    pub uid: String,
    pub name: String,
    pub is_default: bool,
    pub exclusive_supported: bool,
}
#[derive(Clone, Debug, Default, PartialEq)]
pub struct OutputInfo {
    pub device_name: String,
    pub device_uid: String,
    pub sample_rate: u32,
    pub channels: u32,
    pub internal_format: u32,
    pub period_frames: u32,
    pub periods: u32,
    pub period_seconds: f64,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutputConfiguration {
    pub device_uid: Option<String>,
    pub exclusive: bool,
    pub resampling_enabled: bool,
    pub target_sample_rate: u32,
}
/// User-selectable PCM rates, mirrored by the control schema and Dart SDK.
pub const RESAMPLING_SAMPLE_RATES: [u32; 6] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000];
impl Default for OutputConfiguration {
    fn default() -> Self {
        Self {
            device_uid: None,
            exclusive: false,
            resampling_enabled: false,
            target_sample_rate: 48_000,
        }
    }
}

/// Control-thread logging only; callers must never invoke this from render.
pub fn log_sample_rates(
    event: &'static str,
    system_rate: Option<u32>,
    source_rate: Option<u32>,
    pcm_rate: Option<u32>,
    config: &OutputConfiguration,
) {
    let rate = |value: Option<u32>| value.map_or_else(|| "unknown".into(), |v| v.to_string());
    let line = format!(
        "Fideflow audio event={event} system_rate_hz={} source_rate_hz={} pcm_rate_hz={} target_rate_hz={} resampling_enabled={} exclusive={}",
        rate(system_rate),
        rate(source_rate),
        rate(pcm_rate),
        config.target_sample_rate,
        config.resampling_enabled,
        config.exclusive,
    );
    #[cfg(target_os = "android")]
    if let Ok(message) = CString::new(line) {
        unsafe extern "C" {
            fn __android_log_write(
                priority: c_int,
                tag: *const c_char,
                text: *const c_char,
            ) -> c_int;
        }
        let _ = unsafe { __android_log_write(4, c"FideflowAudio".as_ptr(), message.as_ptr()) };
    }
    #[cfg(not(target_os = "android"))]
    {
        use std::io::Write;
        let _ = writeln!(std::io::stderr().lock(), "{line}");
    }
}
/// Keeps PA initialization and HAL listeners alive, even without an open stream.
pub struct OutputContext;
impl OutputContext {
    /// Initializes device control.
    ///
    /// # Errors
    /// Returns an error when the backend cannot initialize.
    pub fn new() -> Result<Self, OutputError> {
        if !is_available() {
            return Err(OutputError::Unavailable);
        }
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if unsafe { native::ff_context_acquire() } != 0 {
            return Err(OutputError::DeviceEnumeration);
        }
        Ok(Self)
    }
    /// Refreshes the device list.
    ///
    /// # Errors
    /// Returns an error when enumeration fails.
    pub fn refresh(&self) -> Result<Vec<PlaybackDevice>, OutputError> {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        devices_locked()
    }
    /// Reads available output devices.
    ///
    /// # Errors
    /// Returns an error when enumeration fails.
    pub fn devices(&self) -> Result<Vec<PlaybackDevice>, OutputError> {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        devices_locked()
    }
    #[must_use]
    pub fn changes(&self) -> u32 {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        unsafe { native::ff_output_changes() }
    }
    pub fn route_valid(&self, uid: Option<&str>) -> bool {
        let Ok(uid) = CString::new(uid.unwrap_or("")) else {
            return false;
        };
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        unsafe { native::ff_output_route_valid(uid.as_ptr()) != 0 }
    }
    pub fn default_uid(&self) -> Option<String> {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut text = [0; 1024];
        if unsafe { native::ff_output_default_uid(text.as_mut_ptr(), text.len()) } != 0 {
            return None;
        }
        Some(fixed(&text))
    }
    /// Negotiates the output channel count.
    ///
    /// # Errors
    /// Returns an error for an invalid or unavailable device.
    pub fn negotiate_channels(
        &self,
        config: &OutputConfiguration,
        preferred: u32,
    ) -> Result<u32, OutputError> {
        reject_unsupported_exclusive(config)?;
        let uid = CString::new(config.device_uid.as_deref().unwrap_or(""))
            .map_err(|_| OutputError::DeviceEnumeration)?;
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let channels = unsafe {
            native::ff_output_channels(uid.as_ptr(), preferred, i32::from(config.exclusive))
        };
        if channels == 0 {
            return Err(OutputError::DeviceOpen("outputDeviceUnavailable".into()));
        }
        Ok(channels)
    }
    /// Negotiates the output sample rate.
    ///
    /// # Errors
    /// Returns an error for an unavailable device or unsupported rate.
    pub fn negotiate_rate(
        &self,
        config: &OutputConfiguration,
        preferred: u32,
    ) -> Result<u32, OutputError> {
        reject_unsupported_exclusive(config)?;
        self.configure_session_preferences(config)?;
        let uid = CString::new(config.device_uid.as_deref().unwrap_or(""))
            .map_err(|_| OutputError::DeviceEnumeration)?;
        if config.resampling_enabled {
            // This is the application PCM rate. Shared backends may adapt it to
            // hardware; exclusive open must accept this exact rate or fail.
            return Ok(config.target_sample_rate);
        }
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let rate =
            unsafe { native::ff_output_rate(uid.as_ptr(), preferred, i32::from(config.exclusive)) };
        validate_negotiated_rate(rate, config.exclusive)
    }

    /// Reads the system output rate without applying user preferences or
    /// selecting an exclusive/source rate. This is separate from negotiation
    /// so diagnostics cannot reset an active iOS sample-rate preference.
    ///
    /// # Errors
    /// Returns an error when the route or its system rate is unavailable.
    pub fn system_sample_rate(&self, device_uid: Option<&str>) -> Result<u32, OutputError> {
        let uid =
            CString::new(device_uid.unwrap_or("")).map_err(|_| OutputError::DeviceEnumeration)?;
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let rate = unsafe { native::ff_output_rate(uid.as_ptr(), 0, 0) };
        // Preserve the raw system value in logs so a low-rate fallback remains
        // visible alongside the actual PCM rate. Zero means no rate was read.
        if rate == 0 || rate > 384_000 {
            return Err(OutputError::DeviceOpen("outputDeviceUnavailable".into()));
        }
        Ok(rate)
    }

    /// Applies the iOS hardware preference before opening or negotiating PCM.
    /// Disabling restores the session preference captured before the override.
    /// Other platforms retain their existing device policies.
    ///
    /// # Errors
    /// Returns an error when iOS refuses the preference request.
    pub fn configure_session_preferences(
        &self,
        config: &OutputConfiguration,
    ) -> Result<(), OutputError> {
        reject_unsupported_exclusive(config)?;
        if config.resampling_enabled
            && !RESAMPLING_SAMPLE_RATES.contains(&config.target_sample_rate)
        {
            return Err(OutputError::DeviceOpen("outputOpenFailed".into()));
        }
        #[cfg(all(target_os = "ios", ff_mobile_available))]
        {
            let _guard = CONTROL
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let rate = if config.resampling_enabled {
                config.target_sample_rate
            } else {
                0
            };
            if unsafe { native::ff_output_set_preferred_rate(rate) } != 0 {
                return Err(OutputError::DeviceOpen("outputOpenFailed".into()));
            }
        }
        Ok(())
    }
}
impl Drop for OutputContext {
    fn drop(&mut self) {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        unsafe { native::ff_context_release() };
    }
}
fn devices_locked() -> Result<Vec<PlaybackDevice>, OutputError> {
    let mut entries = vec![RawDevice::default(); 512];
    let count = unsafe { native::ff_output_devices(entries.as_mut_ptr(), entries.len()) };
    if count < 0 {
        return Err(OutputError::DeviceEnumeration);
    }
    Ok(
        entries[..usize::try_from(count).map_err(|_| OutputError::DeviceEnumeration)?]
            .iter()
            .map(|d| PlaybackDevice {
                uid: fixed(&d.uid),
                name: fixed(&d.name),
                is_default: d.is_default != 0,
                exclusive_supported: d.exclusive_supported != 0,
            })
            .collect(),
    )
}
/// Returns device names.
///
/// # Errors
/// Returns an error when device enumeration fails.
pub fn playback_device_names() -> Result<Vec<String>, OutputError> {
    let context = OutputContext::new()?;
    Ok(context.devices()?.into_iter().map(|d| d.name).collect())
}
#[must_use]
pub const fn is_available() -> bool {
    cfg!(any(ff_portaudio_available, ff_mobile_available))
}
#[must_use]
pub const fn version() -> &'static str {
    if cfg!(ff_mobile_available) {
        "0.11.25"
    } else if is_available() {
        "19.7.0"
    } else {
        "unavailable"
    }
}
/// Name of the linked PCM backend (never a decoder).
#[must_use]
pub const fn backend() -> &'static str {
    if cfg!(any(target_os = "android", target_os = "ios")) {
        "miniaudio"
    } else {
        "portaudio"
    }
}
/// Mobile routes are owned by the operating system.
#[must_use]
pub const fn supports_device_selection() -> bool {
    is_available()
        && cfg!(any(
            target_os = "macos",
            target_os = "windows",
            target_os = "linux"
        ))
}
/// Whether this backend can provide exclusive/hog output.
#[must_use]
pub const fn supports_exclusive_mode() -> bool {
    is_available()
        && cfg!(any(
            target_os = "macos",
            target_os = "windows",
            target_os = "linux"
        ))
}
type RenderCallback = Box<dyn FnMut(&mut [f32]) + Send>;
struct RenderState {
    render: RenderCallback,
    channels: usize,
}
pub struct OutputDevice {
    raw: NonNull<c_void>,
    state: *mut RenderState,
    info: OutputInfo,
    _context: OutputContext,
}
// SAFETY: device control is serialized and render closure is Send.
unsafe impl Send for OutputDevice {}
impl OutputDevice {
    /// Starts output on the default device.
    ///
    /// # Errors
    /// Returns an error when output cannot initialize or open.
    pub fn start<F: FnMut(&mut [f32]) + Send + 'static>(
        channels: u32,
        rate: u32,
        period: u32,
        render: F,
    ) -> Result<Self, OutputError> {
        Self::start_configured(
            &OutputConfiguration::default(),
            channels,
            rate,
            period,
            render,
        )
    }
    /// Starts output on the configured device.
    ///
    /// # Errors
    /// Returns an error when the device, geometry or access is unavailable.
    ///
    /// # Panics
    /// Panics if the native backend returns success with an invalid handle.
    pub fn start_configured<F: FnMut(&mut [f32]) + Send + 'static>(
        config: &OutputConfiguration,
        channels: u32,
        rate: u32,
        period: u32,
        render: F,
    ) -> Result<Self, OutputError> {
        reject_unsupported_exclusive(config)?;
        let context = OutputContext::new()?;
        let uid = CString::new(config.device_uid.as_deref().unwrap_or(""))
            .map_err(|_| OutputError::DeviceOpen("outputInvalidDevice".into()))?;
        let state = Box::into_raw(Box::new(RenderState {
            render: Box::new(render),
            channels: channels as usize,
        }));
        let mut raw = std::ptr::null_mut();
        let mut error = [0; 256];
        let guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let result = unsafe {
            native::ff_output_start(
                uid.as_ptr(),
                i32::from(config.exclusive),
                rate.cast_signed(),
                channels.cast_signed(),
                period,
                trampoline,
                state.cast(),
                &raw mut raw,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if result != 0 || raw.is_null() {
            drop(guard);
            unsafe {
                drop(Box::from_raw(state));
            }
            return Err(OutputError::DeviceOpen(fixed(&error)));
        }
        let mut info = RawInfo::default();
        unsafe { native::ff_output_get_info(raw, &raw mut info) };
        drop(guard);
        Ok(Self {
            raw: NonNull::new(raw).unwrap(),
            state,
            info: OutputInfo {
                device_name: fixed(&info.name),
                device_uid: fixed(&info.uid),
                sample_rate: info.rate.cast_unsigned(),
                channels: info.channels.cast_unsigned(),
                internal_format: info.format.cast_unsigned(),
                period_frames: info.period,
                periods: info.periods,
                period_seconds: info.latency,
            },
            _context: context,
        })
    }
    #[must_use]
    pub const fn info(&self) -> &OutputInfo {
        &self.info
    }
    pub fn is_running(&self) -> bool {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        unsafe { native::ff_output_is_running(self.raw.as_ptr()) == 1 }
    }
    pub fn exclusive_active(&self) -> bool {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        unsafe { native::ff_output_hog_owned(self.raw.as_ptr()) == 1 }
    }
    pub fn pause(&mut self) {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        unsafe { native::ff_output_pause(self.raw.as_ptr()) };
    }
    /// Resumes an opened shared output.
    ///
    /// # Errors
    /// Returns an error when restarting the stream fails.
    pub fn resume(&mut self) -> Result<(), OutputError> {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if unsafe { native::ff_output_resume(self.raw.as_ptr()) } == 0 {
            Ok(())
        } else {
            Err(OutputError::DeviceOpen("outputOpenFailed".into()))
        }
    }
}
impl Drop for OutputDevice {
    fn drop(&mut self) {
        let _guard = CONTROL
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        unsafe {
            native::ff_output_release(self.raw.as_ptr());
            drop(Box::from_raw(self.state));
        }
    }
}
unsafe extern "C" fn trampoline(out: *mut f32, frames: c_uint, user: *mut c_void) {
    if out.is_null() || user.is_null() {
        return;
    }
    let state = unsafe { &mut *user.cast::<RenderState>() };
    let out = unsafe { std::slice::from_raw_parts_mut(out, frames as usize * state.channels) };
    if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| (state.render)(out))).is_err() {
        out.fill(0.0);
    }
}
fn fixed(bytes: &[c_char]) -> String {
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(
        &bytes[..end]
            .iter()
            .map(|b| b.to_ne_bytes()[0])
            .collect::<Vec<_>>(),
    )
    .into_owned()
}
#[repr(C)]
#[derive(Clone)]
struct RawDevice {
    uid: [c_char; 1024],
    name: [c_char; 256],
    is_default: c_int,
    exclusive_supported: c_int,
}
impl Default for RawDevice {
    fn default() -> Self {
        Self {
            uid: [0; 1024],
            name: [0; 256],
            is_default: 0,
            exclusive_supported: 0,
        }
    }
}
#[repr(C)]
struct RawInfo {
    name: [c_char; 256],
    uid: [c_char; 1024],
    rate: c_int,
    channels: c_int,
    format: c_int,
    period: c_uint,
    periods: c_uint,
    latency: f64,
}
impl Default for RawInfo {
    fn default() -> Self {
        Self {
            name: [0; 256],
            uid: [0; 1024],
            rate: 0,
            channels: 0,
            format: 0,
            period: 0,
            periods: 0,
            latency: 0.0,
        }
    }
}
#[cfg(any(ff_portaudio_available, ff_mobile_available))]
mod native {
    use super::{RawDevice, RawInfo, c_char, c_int, c_uint, c_void};
    unsafe extern "C" {
        #[cfg(target_os = "ios")]
        pub fn ff_output_set_preferred_rate(rate: c_uint) -> c_int;
        pub fn ff_context_acquire() -> c_int;
        pub fn ff_context_release();
        pub fn ff_output_changes() -> c_uint;
        pub fn ff_output_devices(out: *mut RawDevice, capacity: usize) -> c_int;
        pub fn ff_output_route_valid(uid: *const c_char) -> c_int;
        pub fn ff_output_default_uid(out: *mut c_char, size: usize) -> c_int;
        pub fn ff_output_channels(
            uid: *const c_char,
            preferred: c_uint,
            exclusive: c_int,
        ) -> c_uint;
        pub fn ff_output_rate(uid: *const c_char, rate: c_uint, exclusive: c_int) -> c_uint;
        pub fn ff_output_start(
            uid: *const c_char,
            exclusive: c_int,
            rate: c_int,
            channels: c_int,
            period: c_uint,
            render: unsafe extern "C" fn(*mut f32, c_uint, *mut c_void),
            user: *mut c_void,
            out: *mut *mut c_void,
            error: *mut c_char,
            size: usize,
        ) -> c_int;
        pub fn ff_output_get_info(device: *mut c_void, out: *mut RawInfo) -> c_int;
        pub fn ff_output_is_running(device: *mut c_void) -> c_int;
        pub fn ff_output_hog_owned(device: *mut c_void) -> c_int;
        pub fn ff_output_release(device: *mut c_void);
        pub fn ff_output_pause(device: *mut c_void);
        pub fn ff_output_resume(device: *mut c_void) -> c_int;
    }
}
#[cfg(not(any(ff_portaudio_available, ff_mobile_available)))]
#[allow(unused_variables)]
mod native {
    use super::{RawDevice, RawInfo, c_char, c_int, c_uint, c_void};
    // Keep fallback signatures ABI-compatible with the native C declarations.
    pub unsafe extern "C" fn ff_context_acquire() -> c_int {
        -1
    }
    pub unsafe extern "C" fn ff_context_release() {}
    pub unsafe extern "C" fn ff_output_changes() -> c_uint {
        0
    }
    pub unsafe extern "C" fn ff_output_devices(out: *mut RawDevice, capacity: usize) -> c_int {
        -1
    }
    pub unsafe extern "C" fn ff_output_route_valid(uid: *const c_char) -> c_int {
        0
    }
    pub unsafe extern "C" fn ff_output_default_uid(out: *mut c_char, size: usize) -> c_int {
        -1
    }
    pub unsafe extern "C" fn ff_output_channels(
        uid: *const c_char,
        preferred: c_uint,
        exclusive: c_int,
    ) -> c_uint {
        0
    }
    pub unsafe extern "C" fn ff_output_rate(
        uid: *const c_char,
        rate: c_uint,
        exclusive: c_int,
    ) -> c_uint {
        0
    }
    pub unsafe extern "C" fn ff_output_start(
        uid: *const c_char,
        exclusive: c_int,
        rate: c_int,
        channels: c_int,
        period: c_uint,
        render: unsafe extern "C" fn(*mut f32, c_uint, *mut c_void),
        user: *mut c_void,
        out: *mut *mut c_void,
        error: *mut c_char,
        size: usize,
    ) -> c_int {
        -1
    }
    pub unsafe extern "C" fn ff_output_get_info(device: *mut c_void, out: *mut RawInfo) -> c_int {
        -1
    }
    pub unsafe extern "C" fn ff_output_is_running(device: *mut c_void) -> c_int {
        0
    }
    pub unsafe extern "C" fn ff_output_hog_owned(device: *mut c_void) -> c_int {
        0
    }
    pub unsafe extern "C" fn ff_output_release(device: *mut c_void) {}
    pub unsafe extern "C" fn ff_output_pause(device: *mut c_void) {}
    pub unsafe extern "C" fn ff_output_resume(device: *mut c_void) -> c_int {
        -1
    }
}

#[cfg(test)]
mod resampling_tests {
    use super::*;

    #[test]
    fn linux_exclusive_requires_an_explicit_direct_hardware_route() {
        if !cfg!(target_os = "linux") {
            return;
        }
        for uid in [
            None,
            Some("alsa:default".into()),
            Some("alsa:pulse".into()),
            Some("alsa:plughw:CARD=USB,DEV=0".into()),
        ] {
            let config = OutputConfiguration {
                exclusive: true,
                device_uid: uid,
                ..Default::default()
            };
            assert!(reject_unsupported_exclusive(&config).is_err());
        }
        let config = OutputConfiguration {
            exclusive: true,
            device_uid: Some("alsa:hw:CARD=USB,DEV=0".into()),
            ..Default::default()
        };
        assert!(reject_unsupported_exclusive(&config).is_ok());
    }

    #[test]
    fn automatic_shared_output_falls_back_below_44_1_khz_but_exclusive_keeps_source_rates() {
        for rate in [0, 4000, 8000, 16_000, 22_050, 32_000, 44_099] {
            assert_eq!(validate_negotiated_rate(rate, false).unwrap(), 48_000);
        }
        for rate in [44_100, 48_000, 96_000, 192_000, 384_000] {
            assert_eq!(validate_negotiated_rate(rate, false).unwrap(), rate);
        }
        for rate in [8000, 16_000, 22_050, 32_000, 44_100] {
            assert_eq!(validate_negotiated_rate(rate, true).unwrap(), rate);
        }
        assert!(validate_negotiated_rate(0, true).is_err());
        assert!(validate_negotiated_rate(384_001, false).is_err());
        assert!(validate_negotiated_rate(384_001, true).is_err());
    }

    #[test]
    fn configured_pcm_rate_overrides_source_and_device_policy_only_when_enabled() {
        if !is_available() {
            return;
        }
        let context = OutputContext::new().unwrap();
        for exclusive in [false, true] {
            if exclusive && cfg!(target_os = "linux") {
                continue;
            }
            let mut config = OutputConfiguration {
                exclusive,
                resampling_enabled: true,
                ..OutputConfiguration::default()
            };
            for rate in RESAMPLING_SAMPLE_RATES {
                config.target_sample_rate = rate;
                for source in [44_100, 48_000, 96_000, 192_000] {
                    assert_eq!(context.negotiate_rate(&config, source).unwrap(), rate);
                }
            }
            config.target_sample_rate = 12_345;
            assert!(context.negotiate_rate(&config, 44_100).is_err());
        }
        let Some(device) = context
            .devices()
            .unwrap()
            .into_iter()
            .find(|d| d.is_default)
        else {
            return;
        };
        if cfg!(target_os = "linux") && !device.exclusive_supported {
            return;
        }
        let config = OutputConfiguration {
            device_uid: Some(device.uid),
            exclusive: true,
            target_sample_rate: 192_000,
            ..OutputConfiguration::default()
        };
        // Disabled mode still delegates to the original platform negotiation.
        let uid = CString::new(config.device_uid.as_deref().unwrap()).unwrap();
        for source in [44_100, 48_000] {
            let expected = unsafe { native::ff_output_rate(uid.as_ptr(), source, 1) };
            assert_eq!(context.negotiate_rate(&config, source).unwrap(), expected);
        }
    }
}

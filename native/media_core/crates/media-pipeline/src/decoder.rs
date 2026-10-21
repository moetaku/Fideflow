//! Safe wrapper around the `FFmpeg` C shim.
//!
//! The shim owns `AVFormatContext`, `AVCodecContext` and `SwrContext`; this module
//! only ever holds an opaque pointer and exchanges scalars and float buffers,
//! which is the boundary rule docs/design/boundaries.md sets for native code. Every block returned
//! here is already interleaved 48 kHz stereo float32 (docs/design/playback.md), so callers never
//! deal with `FFmpeg` sample formats, layouts or time bases.

use std::ffi::{CStr, CString, c_char, c_int, c_longlong};
use std::fmt;
use std::path::Path;
use std::ptr::NonNull;
use std::sync::Arc;
use std::sync::atomic::{AtomicI32, Ordering};

/// Sample rate the pipeline negotiates before PCM reaches the ring buffer.
pub const OUTPUT_SAMPLE_RATE: u32 = 48_000;
/// Channel count the pipeline negotiates before PCM reaches the ring buffer.
pub const OUTPUT_CHANNELS: usize = 2;
/// Size of the C-side error text buffer.
const ERROR_TEXT_BYTES: usize = 256;
/// Length of the fixed-size strings in `ff_audio_info`.
const NAME_BYTES: usize = 64;

/// C-side result codes, matching `enum ff_decode_code` in the shim.
const FF_DECODE_OK: c_int = 0;
const FF_DECODE_OPEN_FAILED: c_int = 1;
const FF_DECODE_NO_AUDIO_STREAM: c_int = 2;
const FF_DECODE_UNSUPPORTED_FORMAT: c_int = 3;
const FF_DECODE_DECODE_FAILED: c_int = 4;
const FF_DECODE_SEEK_FAILED: c_int = 5;
const FF_DECODE_END_OF_STREAM: c_int = 6;
const FF_DECODE_CANCELLED: c_int = 7;

#[repr(C)]
struct RawAudioInfo {
    sample_rate: c_int,
    channels: c_int,
    duration_ms: c_longlong,
    codec: [c_char; NAME_BYTES],
    container: [c_char; NAME_BYTES],
    output_rate: c_int,
    output_channels: c_int,
    resampler: [c_char; NAME_BYTES],
}

/// Opaque decoder handle owned by the C shim.
enum RawDecoder {}

unsafe extern "C" {
    fn ff_decoder_is_available() -> c_int;
    fn ff_ffmpeg_version() -> *const c_char;
    fn ff_decoder_open(
        path: *const c_char,
        cancel_flag: *mut c_int,
        error_code: *mut c_int,
        error_text: *mut c_char,
        error_text_size: usize,
    ) -> *mut RawDecoder;
    fn ff_decoder_open_input(
        path: *const c_char,
        cancel: *mut c_int,
        error_code: *mut c_int,
        error_text: *mut c_char,
        error_size: usize,
        opaque: *mut std::ffi::c_void,
        read: unsafe extern "C" fn(*mut std::ffi::c_void, *mut u8, c_int, *mut c_int) -> c_int,
        seek: unsafe extern "C" fn(*mut std::ffi::c_void, i64, c_int, *mut c_int) -> i64,
    ) -> *mut RawDecoder;
    fn ff_decoder_configure_output(decoder: *mut RawDecoder, rate: c_int, channels: c_int)
    -> c_int;
    fn ff_decoder_close(decoder: *mut RawDecoder);
    fn ff_decoder_set_cancel(decoder: *mut RawDecoder, flag: *mut c_int);
    fn ff_decoder_can_reuse_for_seek(decoder: *const RawDecoder) -> c_int;
    fn ff_decoder_was_interrupted(decoder: *const RawDecoder) -> c_int;
    fn ff_decoder_get_info(decoder: *const RawDecoder, out: *mut RawAudioInfo) -> c_int;
    fn ff_decoder_read(
        decoder: *mut RawDecoder,
        out: *mut f32,
        max_frames: c_int,
        frames_out: *mut c_int,
        media_time_us: *mut c_longlong,
    ) -> c_int;
    fn ff_decoder_seek(
        decoder: *mut RawDecoder,
        position_ms: c_longlong,
        actual_media_us: *mut c_longlong,
    ) -> c_int;
}

/// Returns `true` when the pinned `FFmpeg` build is linked into this binary.
///
/// The cfg answers whether the shim was compiled at all; the C symbol proves the
/// translation unit is really in the final link, so a missing archive cannot be
/// mistaken for a working pipeline.
#[must_use]
pub fn is_available() -> bool {
    #[cfg(all(
        any(
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "android",
            target_os = "ios"
        ),
        ff_ffmpeg_available
    ))]
    {
        // SAFETY: the shim has no preconditions and only reports a constant.
        (unsafe { ff_decoder_is_available() } == 1)
    }
    #[cfg(not(all(
        any(
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "android",
            target_os = "ios"
        ),
        ff_ffmpeg_available
    )))]
    {
        false
    }
}

/// Returns the linked `FFmpeg` version, or `"unavailable"` without it.
#[must_use]
pub fn ffmpeg_version() -> &'static str {
    if !is_available() {
        return "unavailable";
    }
    // SAFETY: the shim returns a static NUL-terminated string literal.
    let pointer = unsafe { ff_ffmpeg_version() };
    if pointer.is_null() {
        return "unknown";
    }
    // SAFETY: see above; the pointer is non-null and NUL-terminated for the
    // lifetime of the process.
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .unwrap_or("unknown")
}

/// What the container and codec report about one source.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AudioInfo {
    /// Native sample rate of the source before conversion.
    pub sample_rate: u32,
    /// Native channel count before conversion.
    pub channels: u32,
    /// Container duration in milliseconds, unknown when the format omits it.
    pub duration_ms: Option<u64>,
    /// Codec short name, e.g. `mp3`.
    pub codec: String,
    /// Container short name, e.g. `mp3`.
    pub container: String,
    /// Negotiated output sample rate (docs/design/playback.md).
    pub output_sample_rate: u32,
    /// Negotiated output channel count (docs/design/playback.md).
    pub output_channels: u32,
    /// Resampler engine libswresample actually selected.
    pub resampler: String,
}

/// One block of decoded PCM.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReadBlock {
    /// Frames written into the caller's buffer.
    pub frames: usize,
    /// Media time of the first frame, in microseconds.
    pub media_time_us: u64,
}

/// Failures the decode pipeline reports.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DecodeError {
    /// The pinned `FFmpeg` library is not part of this build.
    Unavailable,
    /// The container could not be opened or stream information was unreadable.
    OpenFailed(String),
    /// The source has no decodable audio stream.
    NoAudioStream(String),
    /// The stream uses a codec or format this build does not carry.
    UnsupportedFormat(String),
    /// Demuxing, decoding or resampling failed.
    DecodeFailed(String),
    /// The container refused to seek.
    SeekFailed(String),
    /// The worker was cancelled; not an error the user should see.
    Cancelled,
}

impl DecodeError {
    /// Stable code reported through the session snapshot and diagnostics.
    #[must_use]
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Unavailable => "decodeUnavailable",
            Self::OpenFailed(_) => "sourceOpenFailed",
            Self::NoAudioStream(_) => "sourceHasNoAudio",
            Self::UnsupportedFormat(_) => "sourceUnsupported",
            Self::DecodeFailed(_) => "decodeFailed",
            Self::SeekFailed(_) => "seekFailed",
            Self::Cancelled => "cancelled",
        }
    }

    /// Returns `true` when retrying the same source could succeed.
    #[must_use]
    pub const fn is_retryable(&self) -> bool {
        matches!(self, Self::OpenFailed(_) | Self::DecodeFailed(_))
    }
}

impl fmt::Display for DecodeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable => {
                formatter.write_str("the FFmpeg pipeline is not compiled into this build")
            }
            Self::OpenFailed(detail) => write!(formatter, "could not open the source: {detail}"),
            Self::NoAudioStream(detail) => write!(formatter, "no audio stream: {detail}"),
            Self::UnsupportedFormat(detail) => write!(formatter, "unsupported format: {detail}"),
            Self::DecodeFailed(detail) => write!(formatter, "decode failed: {detail}"),
            Self::SeekFailed(detail) => write!(formatter, "seek failed: {detail}"),
            Self::Cancelled => formatter.write_str("the read was cancelled"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// An open `FFmpeg` decoder for one source.
///
/// The handle is not `Sync`: one decoder belongs to one worker thread, matching
/// the threading rule in `c/ff_ffmpeg_shim.c`.
pub struct Decoder {
    raw: NonNull<RawDecoder>,
    info: AudioInfo,
    /// Kept alive so the pointer handed to the interrupt callback stays valid.
    cancel: Arc<AtomicI32>,
    input: Option<Box<crate::input::InputReader>>,
}

// SAFETY: the shim documents that a decoder may be moved between threads as long
// as it is only used from one thread at a time; moving it is exactly that.
unsafe impl Send for Decoder {}

impl Decoder {
    /// Opens `path` and prepares the 48 kHz stereo float32 conversion.
    ///
    /// `cancel` is polled during the open call too, so a blocking probe of an
    /// unresponsive source cannot outlive a Stop.
    ///
    /// # Errors
    ///
    /// Returns the classified [`DecodeError`] the shim reported.
    pub fn open(path: &Path, cancel: &Arc<AtomicI32>) -> Result<Self, DecodeError> {
        Self::open_impl(path, cancel, None)
    }
    /// Opens a registered host input or an ordinary file/network source.
    /// # Errors
    /// Returns an open/decode error for missing, revoked or unsupported inputs.
    pub fn open_with_registry(
        path: &Path,
        cancel: &Arc<AtomicI32>,
        registry: &Arc<crate::input::InputRegistry>,
    ) -> Result<Self, DecodeError> {
        let input = if let Some(id) = path.to_str().and_then(|p| p.strip_prefix("ffinput://")) {
            Some(Box::new(
                registry
                    .reader(
                        id.parse()
                            .map_err(|_| DecodeError::OpenFailed("invalid input".into()))?,
                    )
                    .ok_or_else(|| DecodeError::OpenFailed("revoked input".into()))?,
            ))
        } else {
            None
        };
        Self::open_impl(path, cancel, input)
    }
    fn open_impl(
        path: &Path,
        cancel: &Arc<AtomicI32>,
        mut input: Option<Box<crate::input::InputReader>>,
    ) -> Result<Self, DecodeError> {
        if !is_available() {
            return Err(DecodeError::Unavailable);
        }
        let path = as_c_string(path)?;
        let mut error_code = FF_DECODE_OK;
        let mut error_text = [0 as c_char; ERROR_TEXT_BYTES];
        // SAFETY: `path` is a live NUL-terminated string and the out-parameters
        // point at stack storage for the duration of the call.
        let raw = unsafe {
            if let Some(reader) = input.as_mut() {
                ff_decoder_open_input(
                    path.as_ptr(),
                    cancel.as_ptr().cast(),
                    &raw mut error_code,
                    error_text.as_mut_ptr(),
                    error_text.len(),
                    (&raw mut **reader).cast(),
                    input_read,
                    input_seek,
                )
            } else {
                ff_decoder_open(
                    path.as_ptr(),
                    cancel.as_ptr().cast::<c_int>(),
                    &raw mut error_code,
                    error_text.as_mut_ptr(),
                    error_text.len(),
                )
            }
        };
        let Some(raw) = NonNull::new(raw) else {
            return Err(classify(error_code, &error_text));
        };
        // SAFETY: `raw` is a live decoder handle and the flag outlives it through
        // the `Arc` this struct keeps.
        unsafe { ff_decoder_set_cancel(raw.as_ptr(), cancel.as_ptr().cast::<c_int>()) };
        let mut decoder = Self {
            raw,
            info: placeholder_info(),
            cancel: Arc::clone(cancel),
            input,
        };
        decoder.info = decoder.read_info()?;
        Ok(decoder)
    }

    /// Negotiates PCM geometry before the worker starts producing samples.
    ///
    /// # Errors
    /// Returns an unsupported-format error for invalid geometry, or a decoder
    /// error when the negotiated format cannot be read.
    pub fn configure_output(&mut self, rate: u32, channels: u32) -> Result<(), DecodeError> {
        let rate = c_int::try_from(rate)
            .map_err(|_| DecodeError::UnsupportedFormat("output rate".into()))?;
        let channels = c_int::try_from(channels)
            .map_err(|_| DecodeError::UnsupportedFormat("output channels".into()))?;
        let result = unsafe { ff_decoder_configure_output(self.raw.as_ptr(), rate, channels) };
        if result != FF_DECODE_OK {
            return Err(DecodeError::UnsupportedFormat("output format".into()));
        }
        self.info = self.read_info()?;
        Ok(())
    }

    /// Container and codec details for the open source.
    #[must_use]
    pub const fn info(&self) -> &AudioInfo {
        &self.info
    }

    /// Whether the retained I/O context supports seeking without a prior error.
    #[must_use]
    pub fn is_host_input(&self) -> bool {
        self.input.is_some()
    }

    #[must_use]
    pub fn can_reuse_for_seek(&self) -> bool {
        // SAFETY: exclusive worker ownership, no decoder operation is in flight.
        unsafe { ff_decoder_can_reuse_for_seek(self.raw.as_ptr()) != 0 }
    }

    /// Whether an interrupt actually escaped into `FFmpeg`'s I/O state.
    #[must_use]
    pub fn was_interrupted(&self) -> bool {
        // SAFETY: this decoder owns the live handle; the shim reads atomically.
        unsafe { ff_decoder_was_interrupted(self.raw.as_ptr()) != 0 }
    }

    /// Rebinds cancellation after exclusive ownership moves to a new worker.
    pub fn replace_cancel_flag(&mut self, cancel: &Arc<AtomicI32>) {
        // SAFETY: exclusive ownership, and the new Arc is retained before the old
        // flag is dropped. No FFmpeg operation is in flight during this call.
        unsafe { ff_decoder_set_cancel(self.raw.as_ptr(), cancel.as_ptr().cast::<c_int>()) };
        self.cancel = Arc::clone(cancel);
    }

    /// The cancel flag this decoder polls.
    #[must_use]
    pub fn cancel_flag(&self) -> &Arc<AtomicI32> {
        &self.cancel
    }

    fn read_info(&mut self) -> Result<AudioInfo, DecodeError> {
        let mut raw = RawAudioInfo {
            sample_rate: 0,
            channels: 0,
            duration_ms: -1,
            codec: [0; NAME_BYTES],
            container: [0; NAME_BYTES],
            output_rate: 0,
            output_channels: 0,
            resampler: [0; NAME_BYTES],
        };
        // SAFETY: `raw` is a live, writable struct with the layout the shim
        // expects, and the handle is valid until `Drop`.
        let result = unsafe { ff_decoder_get_info(self.raw.as_ptr(), &raw mut raw) };
        if result != FF_DECODE_OK {
            return Err(classify(result, &[]));
        }
        Ok(AudioInfo {
            sample_rate: u32::try_from(raw.sample_rate).unwrap_or(0),
            channels: u32::try_from(raw.channels).unwrap_or(0),
            duration_ms: u64::try_from(raw.duration_ms).ok(),
            codec: fixed_string(&raw.codec),
            container: fixed_string(&raw.container),
            output_sample_rate: u32::try_from(raw.output_rate).unwrap_or(OUTPUT_SAMPLE_RATE),
            output_channels: u32::try_from(raw.output_channels)
                .unwrap_or(u32::try_from(OUTPUT_CHANNELS).unwrap_or(0)),
            resampler: fixed_string(&raw.resampler),
        })
    }

    /// Reads the next block of PCM into `out`, which must hold whole frames.
    ///
    /// Returns `Ok(None)` once the source and the resampler are both drained,
    /// which is the pipeline's EOF signal.
    ///
    /// # Errors
    ///
    /// Returns [`DecodeError::Cancelled`] when the cancel flag was set, or the
    /// classified failure the shim reported.
    pub fn read(&mut self, out: &mut [f32]) -> Result<Option<ReadBlock>, DecodeError> {
        let max_frames = out.len() / self.info.output_channels as usize;
        if max_frames == 0 {
            return Err(DecodeError::DecodeFailed(String::from(
                "the read buffer holds no whole frame",
            )));
        }
        let max_frames = c_int::try_from(max_frames).unwrap_or(c_int::MAX);
        let mut frames: c_int = 0;
        let mut media_time_us: c_longlong = 0;
        // SAFETY: the buffer is live and writable for `max_frames` frames, and the
        // shim only writes whole frames within that bound.
        let result = unsafe {
            ff_decoder_read(
                self.raw.as_ptr(),
                out.as_mut_ptr(),
                max_frames,
                &raw mut frames,
                &raw mut media_time_us,
            )
        };
        match result {
            FF_DECODE_OK => Ok(Some(ReadBlock {
                frames: usize::try_from(frames).unwrap_or(0),
                media_time_us: u64::try_from(media_time_us).unwrap_or(0),
            })),
            FF_DECODE_END_OF_STREAM => Ok(None),
            _ => Err(classify(result, &[])),
        }
    }

    /// Repositions the decoder to `position_ms` and flushes stale state.
    ///
    /// # Errors
    ///
    /// Returns [`DecodeError::SeekFailed`] when the container refuses, and
    /// [`DecodeError::Cancelled`] when the cancel flag was set.
    pub fn seek(&mut self, position_ms: u64) -> Result<u64, DecodeError> {
        let mut actual_us: c_longlong = 0;
        // SAFETY: the handle is live and `actual_us` is a live out-parameter.
        let result = unsafe {
            ff_decoder_seek(
                self.raw.as_ptr(),
                c_longlong::try_from(position_ms).unwrap_or(c_longlong::MAX),
                &raw mut actual_us,
            )
        };
        if result != FF_DECODE_OK {
            return Err(classify(result, &[]));
        }
        Ok(u64::try_from(actual_us).unwrap_or(0))
    }

    /// Returns `true` when the worker was asked to stop.
    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed) != 0
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // SAFETY: `raw` was produced by `ff_decoder_open` and is released once.
        unsafe { ff_decoder_close(self.raw.as_ptr()) };
    }
}

/// Long path for a value we could not classify, used only in diagnostics.
fn placeholder_info() -> AudioInfo {
    AudioInfo {
        sample_rate: 0,
        channels: 0,
        duration_ms: None,
        codec: String::new(),
        container: String::new(),
        output_sample_rate: OUTPUT_SAMPLE_RATE,
        output_channels: u32::try_from(OUTPUT_CHANNELS).unwrap_or(0),
        resampler: String::new(),
    }
}

/// Copies a fixed-size NUL-terminated C string into a `String`.
fn fixed_string(bytes: &[c_char]) -> String {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    // `c_char` is signed on macOS: reinterpret the bytes so a non-ASCII codec or
    // container name survives instead of turning into question marks.
    let text: Vec<u8> = bytes[..end]
        .iter()
        .map(|byte| byte.to_ne_bytes()[0])
        .collect();
    String::from_utf8_lossy(&text).into_owned()
}

/// Maps a shim result code to a `DecodeError`, preferring the shim's text.
///
/// The explicit arm for `FF_DECODE_DECODE_FAILED` keeps the shim's whole code
/// space visible; the wildcard covers a shim newer than this build, and both are
/// a decode failure, so the bodies are the same on purpose.
#[allow(
    clippy::match_same_arms,
    reason = "naming the shim's own decode code next to the wildcard is documentation"
)]
fn classify(code: c_int, error_text: &[c_char]) -> DecodeError {
    let detail = fixed_string(error_text);
    match code {
        FF_DECODE_OPEN_FAILED => DecodeError::OpenFailed(detail),
        FF_DECODE_NO_AUDIO_STREAM => DecodeError::NoAudioStream(detail),
        FF_DECODE_UNSUPPORTED_FORMAT => DecodeError::UnsupportedFormat(detail),
        FF_DECODE_DECODE_FAILED => DecodeError::DecodeFailed(detail),
        FF_DECODE_SEEK_FAILED => DecodeError::SeekFailed(detail),
        FF_DECODE_CANCELLED => DecodeError::Cancelled,
        _ => DecodeError::DecodeFailed(detail),
    }
}

/// Converts a path to the NUL-terminated bytes the shim expects.
fn as_c_string(path: &Path) -> Result<CString, DecodeError> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        CString::new(path.as_os_str().as_bytes())
            .map_err(|_| DecodeError::OpenFailed(String::from("the path contains a NUL byte")))
    }
    #[cfg(not(unix))]
    {
        CString::new(path.to_string_lossy().as_bytes())
            .map_err(|_| DecodeError::OpenFailed(String::from("the path contains a NUL byte")))
    }
}

#[cfg(test)]
mod tests {
    use super::{DecodeError, ffmpeg_version, fixed_string, is_available};
    use std::ffi::c_char;

    #[test]
    fn fixed_string_stops_at_the_terminator() {
        let mut bytes = [0 as c_char; 8];
        for (index, byte) in b"mp3".iter().enumerate() {
            bytes[index] = c_char::try_from(*byte).unwrap_or_default();
        }
        assert_eq!(fixed_string(&bytes), "mp3");
        assert_eq!(fixed_string(&[0; 8]), "");
    }

    #[test]
    fn error_codes_are_stable_and_retryability_is_explicit() {
        assert_eq!(
            DecodeError::OpenFailed(String::new()).code(),
            "sourceOpenFailed"
        );
        assert!(DecodeError::OpenFailed(String::new()).is_retryable());
        assert!(!DecodeError::UnsupportedFormat(String::new()).is_retryable());
        assert!(!DecodeError::Cancelled.is_retryable());
    }

    #[cfg(all(
        any(
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "android",
            target_os = "ios"
        ),
        ff_ffmpeg_available
    ))]
    #[test]
    fn cancellation_interrupts_a_blocked_source_open() {
        use std::path::Path;
        use std::sync::Arc;
        use std::sync::atomic::{AtomicI32, Ordering};
        use std::time::{Duration, Instant};

        let registry = Arc::new(crate::input::InputRegistry::default());
        assert!(registry.register(1));
        let cancel = Arc::new(AtomicI32::new(0));
        let flag = Arc::clone(&cancel);
        registry.set_sink(Some(Arc::new(move |request, _, _, _| {
            if request != 0 {
                flag.store(1, Ordering::Release);
            }
        })));
        let start = Instant::now();
        let result =
            super::Decoder::open_with_registry(Path::new("ffinput://1"), &cancel, &registry);
        let elapsed = start.elapsed();
        assert!(matches!(result, Err(DecodeError::Cancelled)));
        assert!(elapsed < Duration::from_secs(3));
    }

    #[cfg(all(
        any(
            target_os = "macos",
            target_os = "windows",
            target_os = "linux",
            target_os = "android",
            target_os = "ios"
        ),
        ff_ffmpeg_available
    ))]
    #[test]
    fn reports_the_pinned_ffmpeg_version() {
        assert!(is_available());
        assert_eq!(
            ffmpeg_version(),
            "7.1.5",
            "the prefix must hold the pinned build"
        );
    }
}

#[cfg(all(
    test,
    any(
        target_os = "macos",
        target_os = "windows",
        target_os = "linux",
        target_os = "android",
        target_os = "ios"
    ),
    ff_ffmpeg_available
))]
mod transparent_pcm_tests {
    use super::*;
    #[test]
    fn target_pcm_rates_drain_and_seek_without_changing_duration_for_either_bit_depth() {
        for bits in [16_u16, 24] {
            for (source, target) in [(44_100_u32, 48_000_u32), (96_000, 44_100), (48_000, 48_000)] {
                let width = bits / 8;
                let size = source * u32::from(width);
                let mut wav = Vec::new();
                wav.extend_from_slice(b"RIFF");
                wav.extend_from_slice(&(36 + size).to_le_bytes());
                wav.extend_from_slice(b"WAVEfmt ");
                wav.extend_from_slice(&16_u32.to_le_bytes());
                wav.extend_from_slice(&1_u16.to_le_bytes());
                wav.extend_from_slice(&1_u16.to_le_bytes());
                wav.extend_from_slice(&source.to_le_bytes());
                wav.extend_from_slice(&(source * u32::from(width)).to_le_bytes());
                wav.extend_from_slice(&width.to_le_bytes());
                wav.extend_from_slice(&bits.to_le_bytes());
                wav.extend_from_slice(b"data");
                wav.extend_from_slice(&size.to_le_bytes());
                let value = 1_i32 << (bits - 3);
                for _ in 0..source {
                    wav.extend_from_slice(&value.to_le_bytes()[..usize::from(width)]);
                }
                let path = std::env::temp_dir().join(format!(
                    "ff-target-{}-{bits}-{source}-{target}.wav",
                    std::process::id()
                ));
                std::fs::write(&path, wav).unwrap();
                let cancel = Arc::new(AtomicI32::new(0));
                let mut decoder = Decoder::open(&path, &cancel).unwrap();
                decoder.configure_output(target, 1).unwrap();
                assert_eq!(decoder.info().sample_rate, source);
                assert_eq!(decoder.info().output_sample_rate, target);
                let mut buffer = [0.0; 4096];
                let mut frames = 0_usize;
                while let Some(block) = decoder.read(&mut buffer).unwrap() {
                    frames += block.frames;
                    assert!(
                        buffer[..block.frames]
                            .iter()
                            .all(|sample| sample.is_finite() && sample.abs() < 0.5)
                    );
                }
                assert!(
                    frames.abs_diff(target as usize) <= 2,
                    "{bits}bit {source}->{target}: {frames}"
                );
                decoder.seek(500).unwrap();
                let first = decoder.read(&mut buffer).unwrap().unwrap();
                assert!(first.media_time_us.abs_diff(500_000) <= 1000);
                let mut remaining = first.frames;
                while let Some(block) = decoder.read(&mut buffer).unwrap() {
                    remaining += block.frames;
                }
                assert!(remaining.abs_diff(target as usize / 2) <= 2);
                drop(decoder);
                std::fs::remove_file(path).unwrap();
            }
        }
    }

    #[test]
    #[allow(
        clippy::cast_possible_truncation,
        reason = "expected PCM samples are deliberately quantized to the f32 output format"
    )]
    fn native_16_and_24_bit_pcm_samples_are_preserved() {
        for bits in [16_u16, 24] {
            let maximum = (1_i32 << (bits - 1)) - 1;
            let values: Vec<i32> = [
                -maximum - 1,
                -maximum,
                -65537,
                -257,
                -1,
                0,
                1,
                255,
                256,
                65536,
                maximum,
            ]
            .into_iter()
            .filter(|v| *v >= -maximum - 1 && *v <= maximum)
            .collect();
            let width = bits / 8;
            let size = u32::try_from(values.len()).unwrap() * u32::from(width);
            let mut wav = Vec::new();
            wav.extend_from_slice(b"RIFF");
            wav.extend_from_slice(&(36 + size).to_le_bytes());
            wav.extend_from_slice(b"WAVEfmt ");
            wav.extend_from_slice(&16_u32.to_le_bytes());
            wav.extend_from_slice(&1_u16.to_le_bytes());
            wav.extend_from_slice(&1_u16.to_le_bytes());
            wav.extend_from_slice(&44100_u32.to_le_bytes());
            wav.extend_from_slice(&(44100_u32 * u32::from(width)).to_le_bytes());
            wav.extend_from_slice(&width.to_le_bytes());
            wav.extend_from_slice(&bits.to_le_bytes());
            wav.extend_from_slice(b"data");
            wav.extend_from_slice(&size.to_le_bytes());
            for value in &values {
                wav.extend_from_slice(&value.to_le_bytes()[..width as usize]);
            }
            let path = std::env::temp_dir()
                .join(format!("ff-transparent-{}-{bits}.wav", std::process::id()));
            std::fs::write(&path, wav).unwrap();
            let cancel = Arc::new(AtomicI32::new(0));
            let mut decoder = Decoder::open(&path, &cancel).unwrap();
            decoder.configure_output(44100, 1).unwrap();
            assert_eq!(decoder.info().output_sample_rate, 44100);
            assert_eq!(decoder.info().output_channels, 1);
            let mut actual = Vec::new();
            let mut buffer = [0.0; 128];
            while let Some(block) = decoder.read(&mut buffer).unwrap() {
                actual.extend_from_slice(&buffer[..block.frames]);
            }
            let expected: Vec<f32> = values
                .iter()
                .map(|v| (f64::from(*v) / f64::from(1_u32 << (bits - 1))) as f32)
                .collect();
            assert_eq!(actual, expected);
            drop(decoder);
            std::fs::remove_file(path).unwrap();
        }
    }
}

// C supplies its current cancel flag, including after decoder reuse.
unsafe extern "C" fn input_read(
    opaque: *mut std::ffi::c_void,
    output: *mut u8,
    len: c_int,
    cancel: *mut c_int,
) -> c_int {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let reader = unsafe { &mut *opaque.cast::<crate::input::InputReader>() };
        let cancel = unsafe { &*cancel.cast::<AtomicI32>() };
        let Ok(len) = usize::try_from(len) else {
            return -3;
        };
        let output = unsafe { std::slice::from_raw_parts_mut(output, len) };
        reader
            .read(output, cancel)
            .map_or_else(|e| e, |n| c_int::try_from(n).unwrap_or(-3))
    }))
    .unwrap_or(-3)
}
unsafe extern "C" fn input_seek(
    opaque: *mut std::ffi::c_void,
    offset: i64,
    whence: c_int,
    cancel: *mut c_int,
) -> i64 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        unsafe { &mut *opaque.cast::<crate::input::InputReader>() }
            .seek(offset, whence, unsafe { &*cancel.cast::<AtomicI32>() })
            .unwrap_or(-1)
    }))
    .unwrap_or(-1)
}

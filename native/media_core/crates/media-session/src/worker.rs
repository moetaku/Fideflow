//! The decode worker: one thread per queue item.
//!
//! The worker owns the `FFmpeg` decoder and the only blocking work in the
//! session. It never mutates control state directly; it reports through
//! `Inner::on_primed`, `Inner::on_drained` and `Inner::on_failed`, and every one
//! of those checks the generation first, so a worker that lost a race can never
//! move a queue the user has already left.
//!
//! Two docs/design/playback.md rules live here:
//!
//! * Read-ahead stops at the high watermark and only resumes when the consumer
//!   makes room, so the pipeline cannot accumulate without bound.
//! * Cancellation is checked between blocks *and* handed to the decoder, so a
//!   blocking read, a seek and the open call are all interruptible.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicI32, Ordering};
use std::thread;
use std::time::Duration;

use fideflow_media_pipeline::{DECODE_BLOCK_FRAMES, DecodeError, Decoder, ReadBlock, WriteOutcome};

use crate::{Inner, SourceSummary};

/// How long the worker sleeps while the buffer is above the high watermark.
const FULL_POLL_INTERVAL: Duration = Duration::from_millis(2);

/// Decodes one queue item into the session's PCM ring.
///
/// The handles are taken by value because this is a thread entry point: the
/// worker owns its `Arc`s for the whole item and drops them when it returns, and
/// the cancel flag it shares with the session must outlive every borrow.
#[allow(
    clippy::needless_pass_by_value,
    reason = "thread entry point: the worker owns its handles for the whole item"
)]
pub(crate) fn run(
    inner: Arc<Inner>,
    generation: u64,
    source_uri: String,
    position_ms: u64,
    cancel: Arc<AtomicI32>,
    retire: Arc<AtomicI32>,
    recycled: Option<Decoder>,
) -> Option<Decoder> {
    if !inner.is_current(generation) || cancel.load(Ordering::Relaxed) != 0 {
        return None;
    }
    let path = resolve_source(&source_uri)
        .map_err(|code| inner.on_failed(generation, code, false))
        .ok()?;
    let (mut decoder, mut pending_reuse) =
        prepare_decoder(&inner, generation, &path, position_ms, &cancel, recycled)?;
    let mut channels = decoder.info().output_channels as usize;
    let mut summary = source_summary(&decoder);
    let mut buffer = vec![0.0_f32; DECODE_BLOCK_FRAMES * channels];
    let mut primed = false;
    let mut base_media_us = None;

    loop {
        if retire.load(Ordering::Relaxed) != 0 {
            return Some(decoder);
        }
        // Stop reading ahead at the high watermark; resume once the consumer has
        // made room. This is the pipeline's backpressure signal.
        while inner.realtime.ring.available_frames() >= inner.high_watermark() {
            if retire.load(Ordering::Relaxed) != 0 {
                return Some(decoder);
            }
            thread::sleep(FULL_POLL_INTERVAL);
        }
        let read = decoder.read(&mut buffer);
        // Some demuxers report a successful seek while their AVIO state only
        // reveals the failure on the first read. Validate reuse before PCM.
        let failed_reuse = pending_reuse && reuse_read_failed(&read, &decoder, position_ms);
        if failed_reuse {
            if cancel.load(Ordering::Relaxed) != 0
                || retire.load(Ordering::Relaxed) != 0
                || !inner.is_current(generation)
            {
                return None;
            }
            pending_reuse = false;
            inner
                .realtime
                .seek_decoder_fallbacks
                .fetch_add(1, Ordering::Relaxed);
            drop(decoder);
            decoder = open_positioned(&inner, generation, &path, position_ms, &cancel)?;
            channels = decoder.info().output_channels as usize;
            buffer.resize(DECODE_BLOCK_FRAMES * channels, 0.0);
            summary = source_summary(&decoder);
            continue;
        }
        match read {
            Ok(Some(block)) => {
                if block.frames == 0 {
                    continue;
                }
                base_media_us.get_or_insert(block.media_time_us);
                let samples = &buffer[..block.frames * channels];
                match inner.realtime.ring.write_all(samples, &retire, None) {
                    WriteOutcome::Complete => {
                        if pending_reuse {
                            inner
                                .realtime
                                .seek_decoder_reused
                                .fetch_add(1, Ordering::Relaxed);
                            pending_reuse = false;
                        }
                        inner
                            .realtime
                            .frames_written
                            .fetch_add(block.frames as u64, Ordering::Relaxed);
                    }
                    WriteOutcome::Cancelled => return Some(decoder),
                    WriteOutcome::TimedOut => return None,
                }
                if !primed && inner.realtime.ring.available_frames() >= inner.start_watermark() {
                    primed = true;
                    inner.on_primed(generation, base_media_us.unwrap_or(0), &summary);
                }
            }
            Ok(None) => {
                if pending_reuse {
                    inner
                        .realtime
                        .seek_decoder_reused
                        .fetch_add(1, Ordering::Relaxed);
                }
                // The source and the resampler are both drained. A short file may
                // never have reached the start watermark, so prime it here: the
                // session still needs the source details and the anchor.
                if !primed {
                    inner.on_primed(generation, base_media_us.unwrap_or(0), &summary);
                }
                inner.on_drained(generation);
                return Some(decoder);
            }
            Err(DecodeError::Cancelled) => {
                // Custom AVIO is resettable after a host read is interrupted.
                // Returning it avoids waiting for Dart while a synchronous seek
                // command is still occupying the isolate.
                return (decoder.is_host_input() && retire.load(Ordering::Acquire) != 0)
                    .then_some(decoder);
            }
            Err(error) => {
                let retryable = error.is_retryable();
                inner.on_failed(generation, error.code(), retryable);
                return None;
            }
        }
    }
}

fn reuse_read_failed(
    read: &Result<Option<ReadBlock>, DecodeError>,
    decoder: &Decoder,
    position_ms: u64,
) -> bool {
    match read {
        Err(DecodeError::Cancelled) | Ok(Some(_)) => false,
        Err(_) => true,
        Ok(None) => decoder
            .info()
            .duration_ms
            .is_some_and(|duration| position_ms < duration),
    }
}

fn source_summary(decoder: &Decoder) -> SourceSummary {
    let info = decoder.info();
    SourceSummary {
        duration_ms: info.duration_ms,
        codec: info.codec.clone(),
        source_rate: info.sample_rate,
        source_channels: info.channels,
        resampler: info.resampler.clone(),
    }
}

fn prepare_decoder(
    inner: &Inner,
    generation: u64,
    path: &Path,
    position_ms: u64,
    cancel: &Arc<AtomicI32>,
    recycled: Option<Decoder>,
) -> Option<(Decoder, bool)> {
    if let Some(mut decoder) = recycled {
        decoder.replace_cancel_flag(cancel);
        inner.realtime.seek_stage(generation, 2);
        if decoder.can_reuse_for_seek() && decoder.seek(position_ms).is_ok() {
            inner.realtime.seek_stage(generation, 3);
            if !inner.configure_decoder(generation, &mut decoder) {
                return None;
            }
            return Some((decoder, true));
        }
        inner
            .realtime
            .seek_decoder_fallbacks
            .fetch_add(1, Ordering::Relaxed);
    }
    open_positioned(inner, generation, path, position_ms, cancel).map(|decoder| (decoder, false))
}

fn open_positioned(
    inner: &Inner,
    generation: u64,
    path: &Path,
    position_ms: u64,
    cancel: &Arc<AtomicI32>,
) -> Option<Decoder> {
    if cancel.load(Ordering::Relaxed) != 0 || !inner.is_current(generation) {
        return None;
    }
    if inner.realtime.seek_generation.load(Ordering::Relaxed) == generation {
        inner
            .realtime
            .seek_decoder_reopened
            .fetch_add(1, Ordering::Relaxed);
    }
    let mut decoder = match Decoder::open_with_registry(path, cancel, &inner.input) {
        Ok(decoder) => decoder,
        Err(error) => {
            report_decode_failure(inner, generation, &error);
            return None;
        }
    };
    inner.realtime.seek_stage(generation, 2);
    if position_ms > 0
        && let Err(error) = decoder.seek(position_ms)
    {
        report_decode_failure(inner, generation, &error);
        return None;
    }
    inner.realtime.seek_stage(generation, 3);
    // Every fresh decoder starts as 48 kHz stereo, including a decoder opened
    // after the first read disproves seek reuse. Configure before any PCM read.
    if !inner.configure_decoder(generation, &mut decoder) {
        return None;
    }
    Some(decoder)
}

/// Reports a failure that happened while opening or seeking.
fn report_decode_failure(inner: &Inner, generation: u64, error: &DecodeError) {
    if matches!(error, DecodeError::Cancelled) {
        return;
    }
    inner.on_failed(generation, error.code(), error.is_retryable());
}

/// Resolves a caller-supplied source URI to what the decoder opens.
///
/// `file:` URIs become local paths; `ffinput:` references host-owned AVIO.
/// Native networking is disabled: CDN URLs must be resolved by the host.
/// Inputs remain memory-only and are never persisted or logged.
fn resolve_source(source_uri: &str) -> Result<PathBuf, &'static str> {
    if let Some(id) = source_uri.strip_prefix("ffinput://") {
        if id.parse::<u64>().ok().is_none_or(|id| id == 0) {
            return Err("sourceUnsupported");
        }
        return Ok(PathBuf::from(source_uri));
    }
    let Some(rest) = source_uri.strip_prefix("file:") else {
        return Err("sourceUnsupported");
    };
    // Accepted shapes: file:/path, file:///path, file://localhost/path.
    #[cfg(not(windows))]
    let rest = rest.strip_prefix("//").unwrap_or(rest);
    #[cfg(not(windows))]
    let rest = rest.strip_prefix("localhost").unwrap_or(rest);
    #[cfg(windows)]
    let rest = if rest.starts_with("//localhost/") {
        &rest["//localhost".len()..]
    } else if rest.starts_with("///") {
        &rest[2..]
    } else if rest.as_bytes().get(2).is_some_and(u8::is_ascii_alphabetic)
        && rest.as_bytes().get(3) == Some(&b':')
        && rest.starts_with("//")
    {
        // Also accept the legacy file://D:/ form used by native probes.
        &rest[2..]
    } else {
        // file://server/share is a UNC path, retaining the authority slashes.
        rest
    };
    let decoded = percent_decode(rest);
    if decoded.is_empty() || decoded == "//" {
        return Err("sourceUnsupported");
    }
    #[cfg(windows)]
    let decoded = if decoded.starts_with('/')
        && decoded
            .as_bytes()
            .get(1)
            .is_some_and(u8::is_ascii_alphabetic)
        && decoded.as_bytes().get(2) == Some(&b':')
    {
        decoded[1..].to_owned()
    } else {
        decoded
    };
    Ok(PathBuf::from(decoded))
}

/// Decodes `%XX` escapes; other bytes are copied verbatim.
fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut decoded: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let high = hex_value(bytes[index + 1]);
            let low = hex_value(bytes[index + 2]);
            if let (Some(high), Some(low)) = (high, low) {
                decoded.push(high << 4 | low);
                index += 3;
                continue;
            }
        }
        decoded.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

/// Value of one hexadecimal digit.
fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{percent_decode, resolve_source};

    #[test]
    fn reopened_decoder_uses_negotiated_geometry_before_its_first_read() {
        use super::*;
        use crate::PlaybackSession;
        use fideflow_media_output::{OutputConfiguration, OutputContext};

        if !fideflow_media_pipeline::is_available() || !fideflow_media_output::is_available() {
            return;
        }
        let context = OutputContext::new().unwrap();
        let Some(device) = context.devices().unwrap().into_iter().next() else {
            return;
        };
        // Negotiation reads capabilities only; this test never opens transport
        // or acquires Hog Mode. Mono must replace the fresh decoder's stereo.
        let configuration = OutputConfiguration {
            device_uid: Some(device.uid),
            exclusive: true,
            ..OutputConfiguration::default()
        };
        let rate = context.negotiate_rate(&configuration, 44100).unwrap();
        let channels = context.negotiate_channels(&configuration, 1).unwrap();
        assert_eq!(channels, 1);
        let mut wav = Vec::new();
        let data_bytes = 44100_u32 * 2 * 2;
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_bytes).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16_u32.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&44100_u32.to_le_bytes());
        wav.extend_from_slice(&88200_u32.to_le_bytes());
        wav.extend_from_slice(&2_u16.to_le_bytes());
        wav.extend_from_slice(&16_u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_bytes.to_le_bytes());
        for _ in 0..88200 {
            wav.extend_from_slice(&8192_i16.to_le_bytes());
        }
        let path = std::env::temp_dir().join(format!(
            "ff-reopened-format-{}-{}.wav",
            std::process::id(),
            crate::epoch_ms()
        ));
        std::fs::write(&path, wav).unwrap();
        let session = PlaybackSession::new();
        session.inner.core().output_configuration = configuration;
        let generation = session.inner.core().generation;
        let cancel = Arc::new(AtomicI32::new(0));
        // This is the same reopen path used when a recycled decoder's first
        // read fails after an apparently successful seek.
        let mut decoder = open_positioned(&session.inner, generation, &path, 500, &cancel).unwrap();
        assert_eq!(decoder.info().output_sample_rate, rate);
        assert_eq!(decoder.info().output_channels, channels);
        assert_eq!(session.inner.realtime.ring.channels(), 1);
        assert_eq!(session.inner.core().pcm_rate, rate);
        let mut pcm = vec![0.0; DECODE_BLOCK_FRAMES];
        let block = decoder.read(&mut pcm).unwrap().unwrap();
        assert!(block.frames > 0);
        assert!(block.media_time_us.abs_diff(500_000) <= 1000);
        drop(decoder);
        session.shutdown();
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn resolves_the_file_uri_shapes_the_caller_may_send() {
        assert_eq!(
            resolve_source("file:///Users/example/a.mp3").unwrap(),
            std::path::PathBuf::from("/Users/example/a.mp3")
        );
        assert_eq!(
            resolve_source("file://localhost/Users/example/a.mp3").unwrap(),
            std::path::PathBuf::from("/Users/example/a.mp3")
        );
        assert_eq!(
            resolve_source("file:/Users/example/a.mp3").unwrap(),
            std::path::PathBuf::from("/Users/example/a.mp3")
        );
    }

    #[test]
    fn decodes_escaped_paths_and_rejects_other_schemes() {
        assert_eq!(
            resolve_source("file:///Users/example/Aim%20~we%20can%20do%20all~.mp3").unwrap(),
            std::path::PathBuf::from("/Users/example/Aim ~we can do all~.mp3")
        );
        assert_eq!(
            resolve_source("ftp://example.invalid/a.mp3").unwrap_err(),
            "sourceUnsupported"
        );
        assert_eq!(resolve_source("file://").unwrap_err(), "sourceUnsupported");
    }

    #[cfg(windows)]
    #[test]
    fn windows_file_uris_preserve_drives_unc_and_unicode() {
        for uri in [
            "file:///D:/Music/%E4%B8%AD%20name.wav",
            "file://localhost/D:/Music/%E4%B8%AD%20name.wav",
            "file://D:/Music/%E4%B8%AD%20name.wav",
        ] {
            assert_eq!(
                resolve_source(uri).unwrap(),
                std::path::PathBuf::from("D:/Music/中 name.wav")
            );
        }
        assert_eq!(
            resolve_source("file://server/share/%E4%B8%AD.wav").unwrap(),
            std::path::PathBuf::from("//server/share/中.wav")
        );
    }

    #[test]
    fn application_audio_uses_opaque_nonzero_ids() {
        assert_eq!(
            resolve_source("ffinput://1234").unwrap(),
            std::path::PathBuf::from("ffinput://1234")
        );
        for uri in [
            "ffaudio://example.com:1234/audio",
            "ffaudio://127.0.0.1:0/audio",
            "ffaudio://127.0.0.1:1234@evil/audio",
            "ffaudio://127.0.0.1:1234/",
        ] {
            assert_eq!(resolve_source(uri).unwrap_err(), "sourceUnsupported");
        }
    }

    #[test]
    fn rejects_direct_network_urls() {
        for url in [
            "http://cdn.test/audio.mp3",
            "https://cdn.test/audio.flac",
            "tcp://cdn.test:80",
            "http://",
            "https://",
        ] {
            assert_eq!(resolve_source(url).unwrap_err(), "sourceUnsupported");
        }
    }

    #[test]
    fn percent_decoding_keeps_invalid_escapes_verbatim() {
        assert_eq!(percent_decode("a%2Gb"), "a%2Gb");
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("%E4%B8%AD"), "中");
    }
}

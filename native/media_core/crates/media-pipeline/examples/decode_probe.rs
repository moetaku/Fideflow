//! Evidence tool for the Phase 1 decode path (docs/design/playback.md acceptance).
//!
//! Decodes a local file through the real `FFmpeg` pipeline and reports what the
//! contract requires, as one JSON line on stdout: the negotiated 48 kHz stereo
//! float32 format, the resampler engine that was actually selected, the RMS and
//! peak of the decoded samples, media-time continuity and an optional seek.
//!
//! It exits non-zero when the pipeline violates the playback design rather than reporting
//! numbers that merely look plausible. Run it with the native prefix in place:
//!
//! ```text
//! cargo run -p fideflow-media-pipeline --example decode_probe -- <file> [--seek-ms N]
//! ```
//!
//! Only the file name is printed, never the directory: the diagnostics rule in
//! docs/design/diagnostics.md forbids local paths in output, and this tool is quoted into validation documents.

// The report is human-readable metrics: frame counts and durations are converted
// to f64 to print them, and the frame budget is converted back. Nothing here
// needs exact 64-bit integer arithmetic.
#![allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "the probe prints metrics; 2^53 frames is more audio than exists"
)]

use std::env;
use std::fmt::Write as _;
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::AtomicI32;
use std::time::Instant;

use fideflow_media_pipeline::{
    DECODE_BLOCK_FRAMES, DecodeError, Decoder, PCM_CHANNELS, PCM_SAMPLE_RATE, frames_to_micros,
    is_available,
};

/// Tolerance between the container's media time and the frame clock, in
/// microseconds. docs/design/playback.md makes the frame clock authoritative for position, so the
/// container timestamps only have to agree with it, not define it. Reconstructed
/// timestamps differ by a few milliseconds because a frame's samples are resampled
/// 44.1 kHz to 48 kHz and `libswresample` keeps a small filter delay.
const CLOCK_TOLERANCE_US: u64 = 50_000;

/// Summary of one probe run.
struct Report {
    file: String,
    codec: String,
    container: String,
    source_rate: u32,
    source_channels: u32,
    duration_ms: Option<u64>,
    resampler: String,
    frames: u64,
    seconds: f64,
    peak: f32,
    rms: f64,
    first_media_ms: u64,
    last_media_ms: u64,
    clock_drift_ms: f64,
    clock_drift_blocks: u64,
    seek_target_ms: Option<u64>,
    seek_actual_ms: Option<u64>,
    decode_millis: u128,
    failures: Vec<String>,
}

fn main() -> ExitCode {
    let options = match Options::parse(env::args().skip(1)) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}");
            eprintln!(
                "usage: decode_probe <file> [--max-seconds N] [--seek-ms N] [--block-frames N]"
            );
            return ExitCode::from(2);
        }
    };

    if !is_available() {
        eprintln!("the FFmpeg pipeline is not linked into this build");
        println!("{}", failure_json("decodeUnavailable"));
        return ExitCode::FAILURE;
    }

    match run(&options) {
        Ok(report) => {
            println!("{}", report.to_json());
            if report.failures.is_empty() {
                ExitCode::SUCCESS
            } else {
                for failure in &report.failures {
                    eprintln!("FAIL: {failure}");
                }
                ExitCode::FAILURE
            }
        }
        Err(error) => {
            eprintln!("decode failed: {error}");
            println!("{}", failure_json(error.code()));
            ExitCode::FAILURE
        }
    }
}

#[allow(
    clippy::too_many_lines,
    reason = "one linear decode-and-verify pass reads better than split helpers"
)]
fn run(options: &Options) -> Result<Report, DecodeError> {
    let cancel = Arc::new(AtomicI32::new(0));
    let mut decoder = Decoder::open(&options.file, &cancel)?;
    let info = decoder.info().clone();

    let mut failures = Vec::new();
    if info.output_sample_rate != PCM_SAMPLE_RATE {
        failures.push(format!(
            "pipeline negotiated {} Hz instead of {PCM_SAMPLE_RATE} Hz",
            info.output_sample_rate
        ));
    }
    if info.output_channels != u32::try_from(PCM_CHANNELS).unwrap_or(0) {
        failures.push(format!(
            "pipeline negotiated {} channels instead of {PCM_CHANNELS}",
            info.output_channels
        ));
    }
    if info.resampler != "soxr" {
        failures.push(format!(
            "libswresample selected '{}' instead of the SoX Resampler engine",
            info.resampler
        ));
    }

    // Seek before reading, so the evidence covers repositioning and the discard
    // of the samples that precede the target.
    let mut seek_actual_ms = None;
    if let Some(target_ms) = options.seek_ms {
        let actual_us = decoder.seek(target_ms)?;
        seek_actual_ms = Some(actual_us / 1_000);
        if actual_us / 1_000 + 1 < target_ms {
            failures.push(format!(
                "seek reported {} ms for a {target_ms} ms target",
                actual_us / 1_000
            ));
        }
    }

    let mut buffer = vec![0.0_f32; options.block_frames * PCM_CHANNELS];
    let mut frames = 0_u64;
    let mut peak = 0.0_f32;
    let mut sum_of_squares = 0.0_f64;
    let mut first_media_us = None;
    let mut last_media_us = 0_u64;
    let mut max_drift_us = 0_u64;
    let mut drift_blocks = 0_u64;
    let started = Instant::now();

    loop {
        if frames >= options.max_frames(info.duration_ms) {
            break;
        }
        // Mirror the session's seek: decode past a position first, then scrub.
        if let (Some(after_ms), Some(target_ms)) = (options.seek_after_ms, options.seek_ms)
            && frames_to_micros(frames) / 1_000 >= after_ms
            && seek_actual_ms.is_none()
        {
            let actual_us = decoder.seek(target_ms)?;
            seek_actual_ms = Some(actual_us / 1_000);
            first_media_us = None;
            frames = 0;
        }
        let Some(block) = decoder.read(&mut buffer)? else {
            break;
        };
        if block.frames == 0 {
            continue;
        }
        let start = *first_media_us.get_or_insert(block.media_time_us);
        // The frame clock: what the position is derived from once this PCM is
        // consumed. Container timestamps must agree with it.
        let clock_us = start + frames_to_micros(frames);
        let drift = block.media_time_us.abs_diff(clock_us);
        max_drift_us = max_drift_us.max(drift);
        if drift > CLOCK_TOLERANCE_US {
            drift_blocks += 1;
        }
        last_media_us = block.media_time_us + frames_to_micros(block.frames as u64);
        for sample in &buffer[..block.frames * PCM_CHANNELS] {
            peak = peak.max(sample.abs());
            sum_of_squares += f64::from(*sample) * f64::from(*sample);
        }
        frames += block.frames as u64;
    }
    let decode_millis = started.elapsed().as_millis();

    let samples = frames * PCM_CHANNELS as u64;
    let rms = if samples == 0 {
        0.0
    } else {
        (sum_of_squares / samples as f64).sqrt()
    };
    if frames == 0 {
        failures.push(String::from("the pipeline decoded no frames"));
    }
    if peak <= 0.0001 {
        failures.push(String::from("the decoded audio is silent"));
    }
    if drift_blocks > 0 {
        failures.push(format!(
            "media time disagreed with the frame clock by more than {} ms in {drift_blocks} blocks \
             (worst {:.1} ms)",
            CLOCK_TOLERANCE_US / 1_000,
            max_drift_us as f64 / 1_000.0
        ));
    }
    if let Some(target_ms) = options.seek_ms {
        let landed = first_media_us.unwrap_or(0) / 1_000;
        if landed + 1 < target_ms {
            failures.push(format!(
                "the first decoded frame after the seek is at {landed} ms, before the target"
            ));
        }
    }
    let seconds = frames as f64 / f64::from(PCM_SAMPLE_RATE);
    if let Some(duration_ms) = info.duration_ms
        && options.max_seconds.is_none()
        && options.seek_ms.is_none()
    {
        let decoded_ms = seconds * 1_000.0;
        let drift = (decoded_ms - duration_ms as f64).abs();
        if drift > 250.0 {
            failures.push(format!(
                "decoded {decoded_ms:.0} ms against a container duration of {duration_ms} ms"
            ));
        }
    }

    Ok(Report {
        file: options.file_name(),
        codec: info.codec,
        container: info.container,
        source_rate: info.sample_rate,
        source_channels: info.channels,
        duration_ms: info.duration_ms,
        resampler: info.resampler,
        frames,
        seconds,
        peak,
        rms,
        first_media_ms: first_media_us.unwrap_or(0) / 1_000,
        last_media_ms: last_media_us / 1_000,
        clock_drift_ms: max_drift_us as f64 / 1_000.0,
        clock_drift_blocks: drift_blocks,
        seek_target_ms: options.seek_ms,
        seek_actual_ms,
        decode_millis,
        failures,
    })
}

impl Report {
    fn to_json(&self) -> String {
        let duration = self
            .duration_ms
            .map_or_else(|| String::from("null"), |value| value.to_string());
        let seek_target = self
            .seek_target_ms
            .map_or_else(|| String::from("null"), |value| value.to_string());
        let seek_actual = self
            .seek_actual_ms
            .map_or_else(|| String::from("null"), |value| value.to_string());
        let failures = if self.failures.is_empty() {
            String::from("[]")
        } else {
            let items: Vec<String> = self
                .failures
                .iter()
                .map(|failure| format!("\"{}\"", escape(failure)))
                .collect();
            format!("[{}]", items.join(","))
        };
        let realtime = if self.decode_millis == 0 {
            0.0
        } else {
            (self.seconds * 1_000.0) / self.decode_millis as f64
        };
        format!(
            concat!(
                "{{\"probe\":\"decode\",\"file\":\"{}\",\"codec\":\"{}\",\"container\":\"{}\",",
                "\"sourceRate\":{},\"sourceChannels\":{},\"durationMs\":{},",
                "\"resampler\":\"{}\",\"outputRate\":{},\"outputChannels\":{},",
                "\"frames\":{},\"seconds\":{:.3},\"peak\":{:.4},\"rms\":{:.4},",
                "\"firstMediaMs\":{},\"lastMediaMs\":{},",
                "\"clockDriftMs\":{:.1},\"clockDriftBlocks\":{},",
                "\"seekTargetMs\":{},\"seekActualMs\":{},",
                "\"decodeMillis\":{},\"realtimeFactor\":{:.1},\"failures\":{}}}"
            ),
            escape(&self.file),
            escape(&self.codec),
            escape(&self.container),
            self.source_rate,
            self.source_channels,
            duration,
            escape(&self.resampler),
            PCM_SAMPLE_RATE,
            PCM_CHANNELS,
            self.frames,
            self.seconds,
            self.peak,
            self.rms,
            self.first_media_ms,
            self.last_media_ms,
            self.clock_drift_ms,
            self.clock_drift_blocks,
            seek_target,
            seek_actual,
            self.decode_millis,
            realtime,
            failures
        )
    }
}

/// Minimal JSON string escaping; the values come from container metadata.
fn escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            control if control < ' ' => {
                let _ = write!(escaped, "\\u{:04x}", u32::from(control));
            }
            other => escaped.push(other),
        }
    }
    escaped
}

fn failure_json(code: &str) -> String {
    format!("{{\"probe\":\"decode\",\"failures\":[\"{code}\"]}}")
}

/// Probe arguments.
struct Options {
    file: PathBuf,
    max_seconds: Option<f64>,
    seek_ms: Option<u64>,
    /// Decode until this media time before seeking, mirroring a session that is
    /// already playing when the user scrubs.
    seek_after_ms: Option<u64>,
    block_frames: usize,
}

impl Options {
    fn parse(mut arguments: impl Iterator<Item = String>) -> Result<Self, String> {
        let mut file = None;
        let mut max_seconds = None;
        let mut seek_ms = None;
        let mut seek_after_ms = None;
        let mut block_frames = DECODE_BLOCK_FRAMES;

        while let Some(argument) = arguments.next() {
            match argument.as_str() {
                "--max-seconds" => {
                    let value = arguments.next().ok_or("--max-seconds needs a value")?;
                    max_seconds = Some(value.parse().map_err(|_| "--max-seconds needs a number")?);
                }
                "--seek-ms" => {
                    let value = arguments.next().ok_or("--seek-ms needs a value")?;
                    seek_ms = Some(value.parse().map_err(|_| "--seek-ms needs a number")?);
                }
                "--seek-after-ms" => {
                    let value = arguments.next().ok_or("--seek-after-ms needs a value")?;
                    seek_after_ms = Some(
                        value
                            .parse()
                            .map_err(|_| "--seek-after-ms needs a number")?,
                    );
                }
                "--block-frames" => {
                    let value = arguments.next().ok_or("--block-frames needs a value")?;
                    let frames: usize =
                        value.parse().map_err(|_| "--block-frames needs a number")?;
                    if frames == 0 {
                        return Err(String::from("--block-frames must be at least one frame"));
                    }
                    block_frames = frames;
                }
                other if other.starts_with("--") => {
                    return Err(format!("unknown option '{other}'"));
                }
                other => {
                    if file.is_some() {
                        return Err(String::from("only one file may be probed"));
                    }
                    file = Some(PathBuf::from(other));
                }
            }
        }
        Ok(Self {
            file: file.ok_or("a file to decode is required")?,
            max_seconds,
            seek_ms,
            seek_after_ms,
            block_frames,
        })
    }

    /// Frame budget for this run: the explicit limit, or the whole file.
    fn max_frames(&self, duration_ms: Option<u64>) -> u64 {
        if let Some(seconds) = self.max_seconds {
            return (seconds * f64::from(PCM_SAMPLE_RATE)) as u64;
        }
        duration_ms.map_or(u64::MAX, |duration| {
            duration.saturating_mul(u64::from(PCM_SAMPLE_RATE)) / 1_000 + u64::from(PCM_SAMPLE_RATE)
        })
    }

    /// File name only; docs/design/diagnostics.md keeps local paths out of tool output.
    fn file_name(&self) -> String {
        self.file
            .file_name()
            .map_or_else(String::new, |name| name.to_string_lossy().into_owned())
    }
}

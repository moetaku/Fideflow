//! `FFmpeg` decode pipeline for the `Fideflow` native host (docs/design/playback.md, docs/design/native-build.md).
//!
//! Responsibilities, in the order audio flows through them:
//!
//! 1. [`Decoder`] demuxes, decodes and resamples one source through the C shim,
//!    always producing interleaved 48 kHz stereo float32 PCM.
//! 2. [`PcmRing`] is the bounded hand-off to the output device: the decode worker
//!    writes, the `Core Audio` callback reads.
//!
//! The crate deliberately knows nothing about queues, playback intent or the
//! control protocol; `media-session` owns those. What lives here is the data
//! plane plus the buffer policy docs/design/playback.md fixes for it.
//!
//! Without the pinned native prefix (`tooling/native/macos/build.sh build`) the
//! crate still compiles: [`is_available`] reports `false` and every decode call
//! fails with [`DecodeError::Unavailable`]. That keeps `cargo test` usable on a
//! fresh checkout and on non-macOS CI.

mod decoder;
pub mod input;
mod ring;

pub use decoder::{
    AudioInfo, DecodeError, Decoder, OUTPUT_CHANNELS, OUTPUT_SAMPLE_RATE, ReadBlock,
    ffmpeg_version, is_available,
};
pub use ring::{PcmRing, WriteOutcome};

/// PCM format the pipeline negotiates, as a sample rate.
pub const PCM_SAMPLE_RATE: u32 = OUTPUT_SAMPLE_RATE;
/// PCM format the pipeline negotiates, as a channel count.
pub const PCM_CHANNELS: usize = OUTPUT_CHANNELS;

/// The ring must be able to hold the whole high watermark plus its slack.
///
/// Checked at compile time rather than in a test, so a watermark change that
/// breaks the invariant cannot even build.
const _: () = assert!(RING_CAPACITY_FRAMES > HIGH_WATERMARK_FRAMES);

/// Frames that must be buffered before output starts (docs/design/playback.md: 500 ms).
pub const START_WATERMARK_FRAMES: usize = frames_for_ms(500);
/// Buffer level that marks the producer as falling behind (docs/design/playback.md: 250 ms).
pub const LOW_WATERMARK_FRAMES: usize = frames_for_ms(250);
/// Buffer level at which the producer stops reading ahead (docs/design/playback.md: 1500 ms).
pub const HIGH_WATERMARK_FRAMES: usize = frames_for_ms(1_500);
/// Ring capacity: the high watermark plus one low watermark of slack.
pub const RING_CAPACITY_FRAMES: usize = HIGH_WATERMARK_FRAMES + LOW_WATERMARK_FRAMES;
/// Frames per decode block: about 85 ms, small enough to keep seeks responsive.
pub const DECODE_BLOCK_FRAMES: usize = frames_for_ms(85);

/// Converts a duration in milliseconds to whole frames at the negotiated rate.
#[must_use]
pub const fn frames_for_ms(milliseconds: usize) -> usize {
    (PCM_SAMPLE_RATE as usize / 1_000) * milliseconds
}

/// Converts a frame count to microseconds at the negotiated rate.
#[must_use]
pub const fn frames_to_micros(frames: u64) -> u64 {
    frames * 1_000_000 / PCM_SAMPLE_RATE as u64
}

/// Converts microseconds to whole frames at the negotiated rate.
#[must_use]
pub const fn micros_to_frames(micros: u64) -> u64 {
    micros * PCM_SAMPLE_RATE as u64 / 1_000_000
}

#[cfg(test)]
mod tests {
    use super::{
        HIGH_WATERMARK_FRAMES, LOW_WATERMARK_FRAMES, PCM_CHANNELS, RING_CAPACITY_FRAMES,
        START_WATERMARK_FRAMES, frames_to_micros, micros_to_frames,
    };

    #[test]
    fn watermarks_follow_the_acceptance_numbers() {
        assert_eq!(START_WATERMARK_FRAMES, 24_000);
        assert_eq!(LOW_WATERMARK_FRAMES, 12_000);
        assert_eq!(HIGH_WATERMARK_FRAMES, 72_000);
        assert_eq!(RING_CAPACITY_FRAMES, 84_000);
    }

    #[test]
    fn the_ring_stays_inside_the_adr_001_pcm_cap() {
        let bytes = RING_CAPACITY_FRAMES * PCM_CHANNELS * size_of::<f32>();
        assert!(
            bytes <= 4 * 1024 * 1024,
            "the PCM ring must stay under the 4 MiB per-session cap (was {bytes} bytes)"
        );
    }

    #[test]
    fn time_conversions_round_trip() {
        assert_eq!(frames_to_micros(48_000), 1_000_000);
        assert_eq!(micros_to_frames(1_000_000), 48_000);
        assert_eq!(frames_to_micros(micros_to_frames(500_000)), 500_000);
    }
}

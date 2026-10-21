//! Bounded interleaved-float PCM ring buffer (docs/design/playback.md).
//!
//! The ring is the only structure shared between the decode worker and the audio
//! callback, so it is built for that split: one producer thread writes blocks,
//! one consumer thread (the `Core Audio` callback) reads them, and neither side
//! blocks the other. The consumer performs no allocation, no locking and no I/O;
//! it copies whole frames and advances an atomic. The producer waits for space by
//! polling a sleep, never by holding a lock the callback would need.
//!
//! Both directions are bounded by the same capacity, which is what makes the
//! "no unbounded accumulation" rule in docs/design/playback.md hold: a producer that wants to
//! buffer more simply has to wait.
//!
//! Safety arguments for the `unsafe` code below:
//!
//! * `data` is only ever touched through `&mut [f32]` slices derived from raw
//!   pointers inside the two halves of the buffer, and each half is written by
//!   exactly one thread.
//! * The producer publishes every write with a `Release` store to `write`; the
//!   consumer reads `write` with an `Acquire` load before copying, so sample
//!   bytes are visible before the frame count that describes them.
//! * The consumer publishes consumed frames with a `Release` store to `read`;
//!   the producer reads `read` with an `Acquire` load before reusing space.
//! * Because `write - read <= capacity` at all times, the producer's free region
//!   and the consumer's filled region never overlap.

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// How long the producer sleeps between checks while the ring is full.
const FULL_POLL_INTERVAL: Duration = Duration::from_millis(2);

/// Reason a blocking write stopped before writing everything.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WriteOutcome {
    /// Every requested frame was written.
    Complete,
    /// The cancel flag was set.
    Cancelled,
    /// The deadline passed with the ring still full.
    TimedOut,
}

/// A bounded single-producer/single-consumer ring of interleaved PCM frames.
pub struct PcmRing {
    data: Box<[UnsafeCell<f32>]>,
    capacity_frames: AtomicUsize,
    channels: AtomicUsize,
    /// Monotonically increasing frame counters; the buffer index is `counter % capacity`.
    write: AtomicUsize,
    read: AtomicUsize,
}

// SAFETY: the ring is designed for exactly one producer and one consumer thread
// and the atomics above establish the required happens-before edges. Sharing it
// across threads is the point of the type; `clear` documents its own constraint.
unsafe impl Send for PcmRing {}
// SAFETY: see the module documentation; no thread can observe a partially
// written frame because frame counts are published with release stores.
unsafe impl Sync for PcmRing {}

impl PcmRing {
    /// Creates a ring holding `capacity_frames` frames of `channels` floats.
    ///
    /// # Panics
    ///
    /// Panics when `capacity_frames` or `channels` is zero.
    #[must_use]
    pub fn new(capacity_frames: usize, channels: usize) -> Self {
        assert!(capacity_frames > 0, "the PCM ring needs at least one frame");
        assert!(channels > 0, "the PCM ring needs at least one channel");
        let samples = vec![0.0_f32; capacity_frames * channels].into_boxed_slice();
        Self {
            data: samples.into_iter().map(UnsafeCell::new).collect(),
            capacity_frames: AtomicUsize::new(capacity_frames),
            channels: AtomicUsize::new(channels),
            write: AtomicUsize::new(0),
            read: AtomicUsize::new(0),
        }
    }

    /// Caller must quiesce both producer and consumer before changing geometry.
    ///
    /// # Panics
    /// Panics if the channel count is outside 1 through 8.
    pub fn configure_channels(&self, channels: usize) {
        assert!((1..=8).contains(&channels));
        self.clear();
        self.channels.store(channels, Ordering::Relaxed);
        self.capacity_frames
            .store(self.data.len() / channels, Ordering::Relaxed);
    }

    /// Capacity in frames.
    #[must_use]
    pub fn capacity_frames(&self) -> usize {
        self.capacity_frames.load(Ordering::Relaxed)
    }

    /// Number of channels per frame.
    #[must_use]
    pub fn channels(&self) -> usize {
        self.channels.load(Ordering::Relaxed)
    }

    /// Frames waiting to be consumed.
    #[must_use]
    pub fn available_frames(&self) -> usize {
        self.write
            .load(Ordering::Acquire)
            .wrapping_sub(self.read.load(Ordering::Acquire))
    }

    /// Frames that can be written before the ring is full.
    #[must_use]
    pub fn free_frames(&self) -> usize {
        self.capacity_frames.load(Ordering::Relaxed) - self.available_frames()
    }

    /// Returns a raw pointer to the sample at `frame` (caller keeps the ordering).
    fn sample_ptr(&self, frame: usize) -> *mut f32 {
        let index = (frame % self.capacity_frames.load(Ordering::Relaxed))
            * self.channels.load(Ordering::Relaxed);
        self.data[index].get()
    }

    /// Writes as many whole frames from `samples` as fit right now.
    ///
    /// Returns the number of frames written, which is zero when the ring is full.
    /// A trailing partial frame in `samples` is ignored.
    pub fn write_frames(&self, samples: &[f32]) -> usize {
        let free = self.free_frames();
        let offered = samples.len() / self.channels.load(Ordering::Relaxed);
        let frames = free.min(offered);
        if frames == 0 {
            return 0;
        }
        let write = self.write.load(Ordering::Relaxed);
        let first = frames.min(
            self.capacity_frames.load(Ordering::Relaxed)
                - write % self.capacity_frames.load(Ordering::Relaxed),
        );
        // SAFETY: `frames <= free`, so the region [write, write + frames) holds no
        // samples the consumer may still read, and each frame is copied as a whole.
        unsafe {
            std::ptr::copy_nonoverlapping(
                samples.as_ptr(),
                self.sample_ptr(write),
                first * self.channels.load(Ordering::Relaxed),
            );
            if frames > first {
                std::ptr::copy_nonoverlapping(
                    samples
                        .as_ptr()
                        .add(first * self.channels.load(Ordering::Relaxed)),
                    self.sample_ptr(write + first),
                    (frames - first) * self.channels.load(Ordering::Relaxed),
                );
            }
        }
        // Publish the samples before the frame count that describes them.
        self.write
            .store(write.wrapping_add(frames), Ordering::Release);
        frames
    }

    /// Writes every frame in `samples`, waiting for space until `deadline`.
    ///
    /// `cancel` is polled between waits so a track change or Stop interrupts a
    /// producer that is limited by the consumer's pace.
    pub fn write_all(
        &self,
        samples: &[f32],
        cancel: &AtomicI32,
        deadline: Option<Instant>,
    ) -> WriteOutcome {
        let total = samples.len() / self.channels.load(Ordering::Relaxed);
        let mut written = 0;
        while written < total {
            if cancel.load(Ordering::Relaxed) != 0 {
                return WriteOutcome::Cancelled;
            }
            let frames =
                self.write_frames(&samples[written * self.channels.load(Ordering::Relaxed)..]);
            if frames > 0 {
                written += frames;
                continue;
            }
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                return WriteOutcome::TimedOut;
            }
            std::thread::sleep(FULL_POLL_INTERVAL);
        }
        WriteOutcome::Complete
    }

    /// Copies up to `out.len() / channels` frames out of the ring.
    ///
    /// This is the audio-callback half: no allocation, no lock, no I/O. Returns
    /// the number of frames actually available, which the caller treats as the
    /// media progress of this period and fills the rest of `out` with silence.
    pub fn read_frames(&self, out: &mut [f32]) -> usize {
        let channels = self.channels.load(Ordering::Relaxed);
        let wanted = out.len() / channels;
        let read = self.read.load(Ordering::Relaxed);
        let write = self.write.load(Ordering::Acquire);
        let frames = wanted.min(write.wrapping_sub(read));
        if frames == 0 {
            return 0;
        }
        let first = frames.min(
            self.capacity_frames.load(Ordering::Relaxed)
                - read % self.capacity_frames.load(Ordering::Relaxed),
        );
        // SAFETY: `frames <= write - read`, so every sample copied was published
        // by the producer and cannot be rewritten until `read` advances below.
        unsafe {
            std::ptr::copy_nonoverlapping(
                self.sample_ptr(read).cast_const(),
                out.as_mut_ptr(),
                first * channels,
            );
            if frames > first {
                std::ptr::copy_nonoverlapping(
                    self.sample_ptr(read + first).cast_const(),
                    out.as_mut_ptr().add(first * channels),
                    (frames - first) * channels,
                );
            }
        }
        self.read
            .store(read.wrapping_add(frames), Ordering::Release);
        frames
    }

    /// Discards every buffered frame.
    ///
    /// Only call this while the consumer is quiescent (output stopped), which is
    /// how the session uses it for seek, Stop and item changes.
    pub fn clear(&self) {
        self.read
            .store(self.write.load(Ordering::Acquire), Ordering::Release);
    }
}

#[cfg(test)]
mod tests {
    use super::{PcmRing, WriteOutcome};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicI32, Ordering};

    #[test]
    fn frame_counts_track_writes_and_reads() {
        let ring = PcmRing::new(8, 2);
        assert_eq!(ring.free_frames(), 8);

        let block: Vec<f32> = (0..12_u16).map(f32::from).collect();
        assert_eq!(ring.write_frames(&block), 6, "only six whole frames fit");
        assert_eq!(ring.available_frames(), 6);
        assert_eq!(
            ring.write_frames(&block),
            2,
            "the two frames left of capacity are still accepted"
        );
        assert_eq!(ring.available_frames(), 8);
        assert_eq!(ring.write_frames(&block), 0, "a full ring accepts nothing");

        let mut out = [0.0_f32; 8];
        assert_eq!(ring.read_frames(&mut out), 4);
        assert_eq!(out[..8], block[..8]);
        assert_eq!(ring.available_frames(), 4);
    }

    #[test]
    fn reads_wrap_around_the_end_of_the_buffer() {
        let ring = PcmRing::new(4, 1);
        let mut out = [0.0_f32; 3];

        ring.write_frames(&[1.0, 2.0, 3.0]);
        assert_eq!(ring.read_frames(&mut out), 3);
        // Land the write cursor past the end, then read across the wrap point.
        ring.write_frames(&[4.0, 5.0, 6.0, 7.0]);
        assert_eq!(ring.read_frames(&mut out[..2]), 2);
        assert_eq!(out[..2], [4.0, 5.0]);
        assert_eq!(ring.read_frames(&mut out[..2]), 2);
        assert_eq!(out[..2], [6.0, 7.0]);
    }

    #[test]
    fn producer_waits_for_capacity_and_sees_every_frame() {
        let ring = Arc::new(PcmRing::new(16, 1));
        let cancel = Arc::new(AtomicI32::new(0));
        let producer_ring = Arc::clone(&ring);
        let producer_cancel = Arc::clone(&cancel);

        let producer = std::thread::spawn(move || {
            let block: Vec<f32> = (0..64_u16).map(f32::from).collect();
            let outcome = producer_ring.write_all(&block, &producer_cancel, None);
            assert_eq!(outcome, WriteOutcome::Complete);
        });

        let mut seen = Vec::new();
        let mut out = [0.0_f32; 8];
        while seen.len() < 64 {
            let frames = ring.read_frames(&mut out);
            seen.extend_from_slice(&out[..frames]);
            if frames == 0 {
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        }
        producer.join().unwrap();

        let expected: Vec<f32> = (0..64_u16).map(f32::from).collect();
        assert_eq!(
            seen, expected,
            "the ring must preserve order and every frame"
        );
    }

    #[test]
    fn cancelling_releases_a_blocked_producer() {
        let ring = PcmRing::new(4, 1);
        ring.write_frames(&[1.0, 2.0, 3.0, 4.0]);
        let cancel = AtomicI32::new(0);

        let filler = [9.0_f32; 8];
        // `cancel` and `ring` outlive the thread by borrowing, so the flag can be
        // set while the producer is blocked in `write_all`.
        std::thread::scope(|scope| {
            let handle = scope.spawn(|| ring.write_all(&filler, &cancel, None));
            cancel.store(1, Ordering::Relaxed);
            assert_eq!(
                handle.join().unwrap(),
                WriteOutcome::Cancelled,
                "a full ring plus a set flag must not spin forever"
            );
        });
    }

    #[test]
    fn clear_drops_buffered_frames() {
        let ring = PcmRing::new(4, 1);
        ring.write_frames(&[1.0, 2.0, 3.0]);
        ring.clear();
        assert_eq!(ring.available_frames(), 0);
        let mut out = [0.0_f32; 4];
        assert_eq!(ring.read_frames(&mut out), 0);
        assert_eq!(ring.write_frames(&[4.0, 5.0]), 2);
    }
}

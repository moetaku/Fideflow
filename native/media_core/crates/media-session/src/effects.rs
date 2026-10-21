//! Song gain validation and lock-free, sample-clocked playback envelopes.
use serde_json::{Map, Value};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

pub const FADE_MS: u32 = 300;

/// Store floating-point wire values as bits to retain control-plane equality.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Normalization {
    gain_db: Option<u64>,
    peak: Option<u64>,
}
impl Normalization {
    pub fn from_json(value: &Map<String, Value>) -> Self {
        let finite = |key| {
            value
                .get(key)
                .and_then(Value::as_f64)
                .filter(|v| v.is_finite())
        };
        Self {
            gain_db: finite("normalizationGainDb").map(f64::to_bits),
            peak: finite("normalizationPeak")
                .filter(|v| *v > 0.0)
                .map(f64::to_bits),
        }
    }
    pub fn gain(self) -> Option<f32> {
        let gain = 10_f64.powf(f64::from_bits(self.gain_db?) / 20.0);
        if !gain.is_finite() || gain <= 0.0 || gain > f64::from(f32::MAX) {
            return None;
        }
        // Peak limiting is disabled to match the observed NCM playback behavior.
        // if let Some(peak) = self.peak {
        //     gain = gain.min(1.0 / f64::from_bits(peak));
        // }
        #[allow(clippy::cast_possible_truncation)]
        let gain = gain as f32;
        (gain.is_finite() && gain > 0.0).then_some(gain)
    }
}

/// Only the callback advances a ramp. Control publishes target and revision in
/// one atomic word; gated resets run only while the callback is quiescent.
pub struct Ramp {
    requested: AtomicU64,
    observed: AtomicU32,
    current: AtomicU32,
    remaining: AtomicU32,
}
impl Ramp {
    pub fn new(value: f32) -> Self {
        Self {
            requested: AtomicU64::new(u64::from(value.to_bits())),
            observed: AtomicU32::new(0),
            current: AtomicU32::new(value.to_bits()),
            remaining: AtomicU32::new(0),
        }
    }
    pub fn request(&self, value: f32) {
        let _ = self
            .requested
            .fetch_update(Ordering::Release, Ordering::Relaxed, |old| {
                Some(((old >> 32).wrapping_add(1) << 32) | u64::from(value.to_bits()))
            });
    }
    pub fn reset(&self, value: f32) {
        self.request(value);
        let request = self.requested.load(Ordering::Acquire);
        self.current.store(value.to_bits(), Ordering::Relaxed);
        self.remaining.store(0, Ordering::Relaxed);
        self.observed
            .store((request >> 32) as u32, Ordering::Relaxed);
    }
    pub fn value(&self) -> f32 {
        f32::from_bits(self.current.load(Ordering::Relaxed))
    }
    pub fn begin(&self, rate: u32) -> RampBlock {
        let request = self.requested.load(Ordering::Acquire);
        let revision = (request >> 32) as u32;
        #[allow(clippy::cast_possible_truncation)]
        let target = f32::from_bits(request as u32);
        let remaining = if revision == self.observed.load(Ordering::Relaxed) {
            self.remaining.load(Ordering::Relaxed)
        } else {
            self.observed.store(revision, Ordering::Relaxed);
            rate.saturating_mul(FADE_MS) / 1000
        };
        RampBlock {
            current: self.value(),
            target,
            remaining,
        }
    }
    pub fn finish(&self, block: &RampBlock) {
        self.current
            .store(block.current.to_bits(), Ordering::Relaxed);
        self.remaining.store(block.remaining, Ordering::Relaxed);
    }
}
pub struct RampBlock {
    current: f32,
    target: f32,
    remaining: u32,
}
impl RampBlock {
    pub fn next(&mut self) -> f32 {
        if self.remaining == 0 {
            self.current = self.target;
        } else {
            #[allow(clippy::cast_precision_loss)]
            let remaining = self.remaining as f32;
            self.current += (self.target - self.current) / remaining;
            self.remaining -= 1;
            if self.remaining == 0 {
                self.current = self.target;
            }
        }
        self.current
    }
}

#[cfg(test)]
#[allow(clippy::float_cmp, clippy::needless_pass_by_value)]
mod tests {
    use super::*;
    use serde_json::json;
    fn gain(db: Value, peak: Value) -> Option<f32> {
        Normalization::from_json(
            json!({"normalizationGainDb":db,"normalizationPeak":peak})
                .as_object()
                .unwrap(),
        )
        .gain()
    }
    #[test]
    fn provider_gain_is_db_and_peak_does_not_limit_gain() {
        assert!((gain(json!(-10.7206), Value::Null).unwrap() - 0.291_052).abs() < 0.000_001);
        assert!((gain(json!(3.0815), json!(0.6215)).unwrap() - 1.425_854).abs() < 0.000_001);
        assert_eq!(gain(json!(0), json!(0)), Some(1.0));
        assert_eq!(gain(json!(20), json!(0.5)), Some(10.0));
        assert_eq!(gain(json!(20), json!(f64::MAX)), Some(10.0));
        assert_eq!(gain(json!("3"), Value::Null), None);
        assert_eq!(gain(json!(10000), Value::Null), None);
        assert_eq!(gain(json!(-10000), Value::Null), None);
    }
    #[test]
    fn effective_ncm_gain_is_applied_once() {
        assert!((gain(json!(-4.2522), json!(1)).unwrap() - 0.612_900_5).abs() < 0.000_001);
        assert!((gain(json!(7.5004), json!(0)).unwrap() - 2.371_483).abs() < 0.000_01);
        assert!((gain(json!(7.5004), json!(1)).unwrap() - 2.371_483).abs() < 0.000_01);
    }
    #[test]
    fn ramps_use_sample_rate_and_continue_from_current_level() {
        for rate in [44100, 48000, 96000] {
            let ramp = Ramp::new(1.0);
            ramp.request(0.0);
            let mut block = ramp.begin(rate);
            for _ in 0..rate * FADE_MS / 1000 / 2 {
                block.next();
            }
            ramp.finish(&block);
            assert!((ramp.value() - 0.5).abs() < 0.001);
            ramp.request(1.0);
            let mut block = ramp.begin(rate);
            assert!(block.next() > ramp.value());
            for _ in 1..rate * FADE_MS / 1000 {
                block.next();
            }
            ramp.finish(&block);
            assert_eq!(ramp.value(), 1.0);
        }
    }
}

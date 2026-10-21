//! Bounded asynchronous compressed input. No Dart call runs on the audio thread.
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicI32, AtomicU64, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

pub const BLOCK_BYTES: usize = 64 * 1024;
pub const READER_BLOCKS: usize = 4;
// Leave 4 MiB for pending persistence and 2 MiB for host range fills, plus
// AVIO/network staging inside the shared 8 MiB compressed-input envelope.
pub const MAX_INPUT_BYTES: usize = 1024 * 1024;
#[derive(Default)]
struct BufferPool {
    free: Mutex<Vec<Vec<u8>>>,
    allocated: AtomicUsize,
}
impl BufferPool {
    fn take(self: &Arc<Self>) -> Option<InputBuffer> {
        if let Some(bytes) = self
            .free
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .pop()
        {
            return Some(InputBuffer {
                bytes,
                pool: self.clone(),
            });
        }
        self.allocated
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n + BLOCK_BYTES <= MAX_INPUT_BYTES).then_some(n + BLOCK_BYTES)
            })
            .ok()?;
        Some(InputBuffer {
            bytes: vec![0; BLOCK_BYTES],
            pool: self.clone(),
        })
    }
}
pub type InputSink = Arc<dyn Fn(u64, u64, u64, i64) + Send + Sync>;
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);
static NEXT_READER: AtomicU64 = AtomicU64::new(1);

pub struct InputRegistry {
    state: Mutex<State>,
    pool: Arc<BufferPool>,
    request_count: AtomicU64,
}
struct State {
    closed: bool,
    readers: usize,
    sources: HashSet<u64>,
    requests: HashMap<u64, Arc<Request>>,
    sink: Option<InputSink>,
}
pub struct InputBuffer {
    pub bytes: Vec<u8>,
    pool: Arc<BufferPool>,
}
impl Drop for InputBuffer {
    fn drop(&mut self) {
        self.pool
            .free
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(std::mem::take(&mut self.bytes));
    }
}
pub struct InputReply {
    pub buffer: InputBuffer,
    pub len: usize,
    pub total: i64,
    pub status: u32,
}
struct Request {
    source: u64,
    reply: Mutex<Option<Result<InputReply, i32>>>,
    ready: Condvar,
    claimed: std::sync::atomic::AtomicBool,
    pool: Arc<BufferPool>,
}
pub struct InputLease {
    request: Arc<Request>,
    pub buffer: InputBuffer,
}
impl InputLease {
    pub fn complete(self, len: usize, total: i64, status: u32) {
        let mut reply = self
            .request
            .reply
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        *reply = Some(Ok(InputReply {
            buffer: self.buffer,
            len,
            total,
            status,
        }));
        self.request.ready.notify_all();
    }
}
impl Default for InputRegistry {
    fn default() -> Self {
        Self {
            state: Mutex::new(State {
                closed: false,
                readers: 0,
                sources: HashSet::new(),
                requests: HashMap::new(),
                sink: None,
            }),
            pool: Arc::new(BufferPool::default()),
            request_count: AtomicU64::new(0),
        }
    }
}
impl InputRegistry {
    pub fn metrics(&self) -> (usize, usize, u64) {
        (
            self.pool.allocated.load(Ordering::Acquire),
            self.state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .readers,
            self.request_count.load(Ordering::Relaxed),
        )
    }
    pub fn interrupt(&self) {
        for request in self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .requests
            .values()
        {
            request.ready.notify_all();
        }
    }

    pub fn set_sink(&self, sink: Option<InputSink>) {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .sink = sink;
    }
    pub fn register(&self, source: u64) -> bool {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        !state.closed && source != 0 && state.sources.len() < 512 && state.sources.insert(source)
    }
    pub fn revoke(&self, source: u64) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.sources.remove(&source);
        for request in state.requests.values() {
            request.ready.notify_all();
        }
    }
    pub fn shutdown(&self) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.closed = true;
        state.sources.clear();
        state.sink = None;
        for request in state.requests.values() {
            request.ready.notify_all();
        }
    }
    pub fn acquire(&self, id: u64) -> Option<InputLease> {
        let state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.closed {
            return None;
        }
        let request = state.requests.get(&id)?.clone();
        if !state.sources.contains(&request.source) {
            return None;
        }
        drop(state);
        if request.claimed.swap(true, Ordering::AcqRel) {
            return None;
        }
        let Some(buffer) = request.pool.take() else {
            *request
                .reply
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Err(-3));
            request.ready.notify_all();
            return None;
        };
        Some(InputLease { request, buffer })
    }
    pub fn reader(self: &Arc<Self>, source: u64) -> Option<InputReader> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.readers >= 2 || !state.sources.contains(&source) {
            return None;
        }
        state.readers += 1;
        drop(state);
        Some(InputReader {
            registry: self.clone(),
            source,
            id: NEXT_READER.fetch_add(1, Ordering::Relaxed),
            position: 0,
            total: -1,
            buffered: VecDeque::with_capacity(READER_BLOCKS),
        })
    }
    fn request(
        &self,
        source: u64,
        reader: u64,
        offset: i64,
        cancel: &AtomicI32,
    ) -> Result<InputReply, i32> {
        self.request_count.fetch_add(1, Ordering::Relaxed);
        let id = NEXT_REQUEST.fetch_add(1, Ordering::Relaxed);
        let request = Arc::new(Request {
            source,
            reply: Mutex::new(None),
            ready: Condvar::new(),
            claimed: std::sync::atomic::AtomicBool::new(false),
            pool: self.pool.clone(),
        });
        {
            // Hold the registration lock through dispatch: unregister/shutdown is a callback barrier.
            let mut state = self
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.closed || cancel.load(Ordering::Acquire) != 0 {
                return Err(-2);
            }
            if !state.sources.contains(&source) {
                return Err(-3);
            }
            let sink = state.sink.clone().ok_or(-3)?;
            state.requests.insert(id, request.clone());
            sink(id, source, reader, offset);
        }
        let deadline = Instant::now() + Duration::from_secs(20);
        let result = loop {
            {
                let state = self
                    .state
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if state.closed || cancel.load(Ordering::Acquire) != 0 {
                    break Err(-2);
                }
                if !state.sources.contains(&source) {
                    break Err(-3);
                }
            }
            let mut reply = request
                .reply
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(reply) = reply.take() {
                break reply;
            }
            if Instant::now() >= deadline {
                break Err(-4);
            }
            reply = request
                .ready
                .wait_timeout(reply, Duration::from_millis(5))
                .unwrap()
                .0;
            drop(reply);
        };
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.requests.remove(&id);
        if result.is_err() {
            // The host may still be filling an independently leased buffer.
            // Retaining this native reader across seek must not reuse that
            // host reader for another read before its old future completes.
            // Dispatch reset before the next request so Dart drops the mapping
            // and closes the old stream, even for a seek inside buffered bytes.
            if let Some(sink) = &state.sink {
                sink(0, source, reader, -3);
            }
        }
        result
    }
}
pub struct InputReader {
    registry: Arc<InputRegistry>,
    source: u64,
    pub id: u64,
    position: i64,
    total: i64,
    buffered: VecDeque<(i64, InputReply)>,
}
impl InputReader {
    /// Reads available bytes; a short read is successful, zero means EOF.
    /// # Errors
    /// Returns -2 for cancellation, -3 for revoked/invalid input or I/O, -4 for timeout.
    pub fn read(&mut self, output: &mut [u8], cancel: &AtomicI32) -> Result<usize, i32> {
        {
            let state = self
                .registry
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.closed || cancel.load(Ordering::Acquire) != 0 {
                return Err(-2);
            }
            if !state.sources.contains(&self.source) {
                return Err(-3);
            }
        }
        for (start, reply) in &self.buffered {
            let relative = self.position - start;
            if let Ok(start) = usize::try_from(relative)
                && start < reply.len
            {
                let n = output.len().min(reply.len - start);
                output[..n].copy_from_slice(&reply.buffer.bytes[start..start + n]);
                self.position += i64::try_from(n).map_err(|_| -3)?;
                return Ok(n);
            }
        }
        // Release before acquiring the next lease: even in-flight fills count
        // toward the four-block reader limit. Do not wait to fill a short block.
        if self.buffered.len() == READER_BLOCKS {
            self.buffered.pop_front();
        }
        let reply = self
            .registry
            .request(self.source, self.id, self.position, cancel)?;
        self.total = reply.total;
        match reply.status {
            0 => {}
            1 => return Ok(0),
            2 => return Err(-2),
            4 => return Err(-4),
            _ => return Err(-3),
        }
        if reply.len == 0 || reply.len > BLOCK_BYTES {
            return Err(-3);
        }
        self.buffered.push_back((self.position, reply));
        self.read(output, cancel)
    }
    /// Repositions inside the current block or resets the host's stream.
    /// # Errors
    /// Returns an error for unknown size, invalid offsets, cancellation or I/O failure.
    pub fn seek(&mut self, offset: i64, whence: i32, cancel: &AtomicI32) -> Result<i64, i32> {
        if whence & 0x10000 != 0 {
            if self.total < 0 {
                let reply = self.registry.request(self.source, self.id, -1, cancel)?;
                if reply.status > 1 {
                    return Err(-3);
                }
                self.total = reply.total;
            }
            return (self.total >= 0).then_some(self.total).ok_or(-3);
        }
        let position = match whence & !0x20000 {
            0 => offset,
            1 => self.position.checked_add(offset).ok_or(-3)?,
            2 if self.total >= 0 => self.total.checked_add(offset).ok_or(-3)?,
            _ => return Err(-3),
        };
        if position < 0 {
            return Err(-3);
        }
        let buffered = self.buffered.iter().any(|(start, reply)| {
            position >= *start && position - start < i64::try_from(reply.len).unwrap_or(i64::MAX)
        });
        if !buffered {
            let state = self
                .registry
                .state
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(sink) = &state.sink {
                sink(0, self.source, self.id, -3);
            }
        }
        self.position = position;
        Ok(position)
    }
}

impl Drop for InputReader {
    fn drop(&mut self) {
        let mut state = self
            .registry
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.readers -= 1;
        if let Some(sink) = &state.sink {
            sink(0, self.source, self.id, -2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::mpsc, thread};

    type Notification = (u64, u64, u64, i64);
    fn setup() -> (Arc<InputRegistry>, mpsc::Receiver<Notification>) {
        let registry = Arc::new(InputRegistry::default());
        assert!(registry.register(7));
        let (tx, rx) = mpsc::channel();
        registry.set_sink(Some(Arc::new(move |a, b, c, d| {
            let _ = tx.send((a, b, c, d));
        })));
        (registry, rx)
    }
    #[test]
    fn short_reads_seek_and_eof_are_distinct() {
        let (registry, rx) = setup();
        let mut reader = registry.reader(7).unwrap();
        let worker = thread::spawn(move || {
            let cancel = AtomicI32::new(0);
            let mut out = [0; 8];
            assert_eq!(reader.read(&mut out, &cancel), Ok(4));
            assert_eq!(&out[..4], &[1, 2, 3, 4]);
            assert_eq!(reader.seek(1, 0, &cancel), Ok(1));
            assert_eq!(reader.read(&mut out, &cancel), Ok(3));
            assert_eq!(&out[..3], &[2, 3, 4]);
            assert_eq!(reader.seek(0, 0x10000, &cancel), Ok(4));
            assert_eq!(reader.seek(4, 0, &cancel), Ok(4));
            assert_eq!(reader.read(&mut out, &cancel), Ok(0));
        });
        let (id, source, _, offset) = rx.recv().unwrap();
        assert_eq!((source, offset), (7, 0));
        let mut lease = registry.acquire(id).unwrap();
        assert!(registry.acquire(id).is_none());
        lease.buffer.bytes[..4].copy_from_slice(&[1, 2, 3, 4]);
        lease.complete(4, 4, 0);
        let (mut id, _, _, mut offset) = rx.recv().unwrap();
        while id == 0 {
            (id, _, _, offset) = rx.recv().unwrap();
        }
        assert_eq!(offset, 4);
        registry.acquire(id).unwrap().complete(0, 4, 1);
        worker.join().unwrap();
    }
    #[test]
    fn cancelled_read_resets_host_before_reusing_native_reader() {
        let (registry, rx) = setup();
        let mut reader = registry.reader(7).unwrap();
        let reader_id = reader.id;
        let cancel = Arc::new(AtomicI32::new(0));
        let flag = cancel.clone();
        let worker = thread::spawn(move || {
            let mut output = [0; 4];
            assert_eq!(reader.read(&mut output, &flag), Ok(4));
            assert_eq!(reader.read(&mut output, &flag), Err(-2));
            let next_flag = AtomicI32::new(0);
            // Buffered seek does not send its own host reset.
            assert_eq!(reader.seek(0, 0, &next_flag), Ok(0));
            assert_eq!(reader.read(&mut output, &next_flag), Ok(4));
            assert_eq!(reader.read(&mut output, &next_flag), Ok(4));
            assert_eq!(output, [2; 4]);
        });
        let (first, _, _, _) = rx.recv().unwrap();
        let mut lease = registry.acquire(first).unwrap();
        lease.buffer.bytes[..4].fill(1);
        lease.complete(4, 8, 0);
        let (cancelled, _, _, offset) = rx.recv().unwrap();
        assert_eq!(offset, 4);
        let mut late = registry.acquire(cancelled).unwrap();
        cancel.store(1, Ordering::Release);
        registry.interrupt();
        assert_eq!(rx.recv().unwrap(), (0, 7, reader_id, -3));
        let (next, source, id, offset) = rx.recv().unwrap();
        assert_eq!((source, id, offset), (7, reader_id, 4));
        // A late old read stays memory-safe and cannot answer the new request.
        late.buffer.bytes[..4].fill(9);
        late.complete(4, 8, 0);
        let mut lease = registry.acquire(next).unwrap();
        lease.buffer.bytes[..4].fill(2);
        lease.complete(4, 8, 0);
        worker.join().unwrap();
    }

    #[test]
    fn cancellation_keeps_a_late_lease_alive_after_registry_shutdown() {
        let (registry, rx) = setup();
        let mut reader = registry.reader(7).unwrap();
        let cancel = Arc::new(AtomicI32::new(0));
        let flag = cancel.clone();
        let worker = thread::spawn(move || reader.read(&mut [0; 8], &flag));
        let (id, _, _, _) = rx.recv().unwrap();
        let mut lease = registry.acquire(id).unwrap();
        let started = Instant::now();
        registry.shutdown();
        assert_eq!(worker.join().unwrap(), Err(-2));
        assert!(started.elapsed() < Duration::from_millis(100));
        assert!(registry.acquire(id).is_none());
        drop(registry);
        lease.buffer.bytes[0] = 9;
        lease.complete(1, -1, 0);
    }
    #[test]
    fn pool_is_reused_and_has_a_hard_limit() {
        let pool = Arc::new(BufferPool::default());
        let buffer = pool.take().unwrap();
        let pointer = buffer.bytes.as_ptr();
        drop(buffer);
        let buffer = pool.take().unwrap();
        assert_eq!(buffer.bytes.as_ptr(), pointer);
        let mut held = vec![buffer];
        for _ in 1..MAX_INPUT_BYTES / BLOCK_BYTES {
            held.push(pool.take().unwrap());
        }
        assert!(pool.take().is_none());
        drop(held);
        assert_eq!(pool.allocated.load(Ordering::Acquire), MAX_INPUT_BYTES);
        assert!(pool.take().is_some());
    }
    #[test]
    fn reader_retains_four_blocks_and_reuses_the_evicted_lease() {
        let (registry, rx) = setup();
        let mut reader = registry.reader(7).unwrap();
        let worker = thread::spawn(move || {
            let cancel = AtomicI32::new(0);
            let mut output = vec![0; BLOCK_BYTES];
            for value in 0..4 {
                assert_eq!(reader.read(&mut output, &cancel), Ok(BLOCK_BYTES));
                assert!(output.iter().all(|byte| *byte == value));
            }
            assert_eq!(reader.seek(1, 0, &cancel), Ok(1));
            assert_eq!(reader.read(&mut output[..1], &cancel), Ok(1));
            assert_eq!(output[0], 0);
            let last = i64::try_from(3 * BLOCK_BYTES).unwrap();
            assert_eq!(reader.seek(last, 0, &cancel), Ok(last));
            assert_eq!(reader.read(&mut output, &cancel), Ok(BLOCK_BYTES));
            assert_eq!(reader.read(&mut output, &cancel), Ok(BLOCK_BYTES));
            assert_eq!(output[0], 4);
        });
        for value in 0..5 {
            let (id, _, _, offset) = rx.recv().unwrap();
            assert_ne!(id, 0, "buffer hits must not reset the host reader");
            assert_eq!(
                offset,
                i64::from(value) * i64::try_from(BLOCK_BYTES).unwrap()
            );
            let mut lease = registry.acquire(id).unwrap();
            lease.buffer.bytes.fill(value);
            lease.complete(BLOCK_BYTES, -1, 0);
        }
        worker.join().unwrap();
        assert_eq!(
            registry.pool.allocated.load(Ordering::Acquire),
            READER_BLOCKS * BLOCK_BYTES
        );
        assert_eq!(registry.request_count.load(Ordering::Relaxed), 5);
    }
    #[test]
    fn revocation_is_scoped_and_reader_count_is_bounded() {
        let (registry, _) = setup();
        assert!(registry.register(8));
        let reader = registry.reader(7).unwrap();
        let mut other = registry.reader(8).unwrap();
        assert!(registry.reader(7).is_none());
        registry.revoke(7);
        drop(reader);
        assert!(registry.reader(7).is_none());
        let cancel = AtomicI32::new(0);
        assert_eq!(other.seek(5, 0, &cancel), Ok(5));
        registry.shutdown();
        assert_eq!(other.read(&mut [0; 1], &cancel), Err(-2));
    }
    #[test]
    fn error_is_not_eof_and_invalid_seek_does_not_change_position() {
        let (registry, rx) = setup();
        let mut reader = registry.reader(7).unwrap();
        let worker = thread::spawn(move || {
            let cancel = AtomicI32::new(0);
            assert!(reader.seek(-1, 0, &cancel).is_err());
            reader.read(&mut [0; 1], &cancel)
        });
        let (id, _, _, offset) = rx.recv().unwrap();
        assert_eq!(offset, 0);
        registry.acquire(id).unwrap().complete(0, -1, 3);
        assert_eq!(worker.join().unwrap(), Err(-3));
    }
}

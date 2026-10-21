//! Additive ABI 3 capability, for in-process NCM requests.
use super::{
    CSink, FF_MEDIA_ERR_INTERNAL, FF_MEDIA_ERR_INVALID_ARGUMENT, FF_MEDIA_ERR_NULL_HANDLE,
    FF_MEDIA_OK, FfEventSink, borrow_str, guard, owned_bytes,
};
use std::{ffi::c_void, sync::Arc};

pub struct FfNcmHost {
    host: fideflow_ncm_host::Host,
}

/// Creates a host without starting any request or listening socket.
/// # Safety
/// `out` must point to writable pointer storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_ncm_host_new(out: *mut *mut FfNcmHost) -> u32 {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    *out = std::ptr::null_mut();
    guard(|| match fideflow_ncm_host::Host::new() {
        Ok(host) => {
            *out = Box::into_raw(Box::new(FfNcmHost { host }));
            FF_MEDIA_OK
        }
        Err(_) => FF_MEDIA_ERR_INTERNAL,
    })
}

/// Submits a bounded request JSON; duplicate active IDs are refused.
/// # Safety
/// `host` must be live; `document` must reference `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_ncm_host_submit(
    host: *mut FfNcmHost,
    document: *const u8,
    len: usize,
) -> u32 {
    let Some(host) = (unsafe { host.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    let document = match unsafe { borrow_str(document, len, 64 * 1024) } {
        Ok(s) => s,
        Err(e) => return e,
    };
    let Some(request) = fideflow_ncm_host::Request::from_json(document) else {
        return FF_MEDIA_ERR_INVALID_ARGUMENT;
    };
    guard(|| {
        if host.host.submit(request) {
            FF_MEDIA_OK
        } else {
            FF_MEDIA_ERR_INVALID_ARGUMENT
        }
    })
}

/// Cancels an ID. No completion is emitted for a successfully cancelled task.
/// # Safety
/// `host` must be live; `id` must reference `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_ncm_host_cancel(
    host: *mut FfNcmHost,
    id: *const u8,
    len: usize,
) -> u32 {
    let Some(host) = (unsafe { host.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    let id = match unsafe { borrow_str(id, len, 128) } {
        Ok(s) => s,
        Err(e) => return e,
    };
    guard(|| {
        host.host.cancel(id);
        FF_MEDIA_OK
    })
}

/// Registers or clears the sink; uses the existing owned byte buffer convention.
/// # Safety
/// `host` must be live. Sink and user remain valid until cleared or freed.
/// The sink must not reenter the ABI and owns every delivered buffer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_ncm_host_set_event_sink(
    host: *mut FfNcmHost,
    sink: FfEventSink,
    user: *mut c_void,
) -> u32 {
    let Some(host) = (unsafe { host.as_ref() }) else {
        return FF_MEDIA_ERR_NULL_HANDLE;
    };
    guard(|| {
        host.host.set_event_sink(sink.map(|sink| {
            let target = Arc::new(CSink { sink, user });
            Arc::new(move |document: &str| {
                let bytes = owned_bytes(document.to_owned());
                // SAFETY: the registered sink owns this buffer and remains live.
                unsafe { (target.sink)(bytes.data, bytes.len, target.user) }
            }) as fideflow_ncm_host::EventSink
        }));
        FF_MEDIA_OK
    })
}

/// Clears the sink, cancels requests and stops the runtime.
/// # Safety
/// `host` must be null or a live handle that has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_ncm_host_free(host: *mut FfNcmHost) {
    if !host.is_null() {
        // SAFETY: the caller transfers ownership of this live handle.
        drop(unsafe { Box::from_raw(host) });
    }
}

/// Counts posted callbacks after the sink has been cleared. The embedding
/// isolate drains these owned buffers before closing its native listener.
/// # Safety
/// `host` must be null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ff_ncm_host_deliveries(host: *const FfNcmHost) -> u64 {
    // SAFETY: the caller guarantees the handle remains live.
    unsafe { host.as_ref() }.map_or(0, |host| host.host.deliveries())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{FfOwnedBytes, ff_owned_bytes_free};
    use std::{ptr, sync::mpsc, time::Duration};

    unsafe extern "C" fn receive(data: *mut u8, len: usize, user: *mut c_void) {
        // SAFETY: the test owns the channel and the ABI transfers this buffer.
        let document = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
        unsafe { ff_owned_bytes_free(FfOwnedBytes { data, len }) };
        let sender = unsafe { &*user.cast::<mpsc::Sender<Vec<u8>>>() };
        let _ = sender.send(document);
    }

    #[test]
    fn optional_host_abi_owns_event_buffers_and_drains_before_free() {
        // SAFETY: every pointer is test-owned storage or a live ABI handle.
        unsafe {
            assert_eq!(ff_ncm_host_new(ptr::null_mut()), FF_MEDIA_ERR_NULL_HANDLE);
            let mut host = ptr::null_mut();
            assert_eq!(ff_ncm_host_new(&raw mut host), FF_MEDIA_OK);
            let (mut sender, receiver) = mpsc::channel::<Vec<u8>>();
            let user = (&raw mut sender).cast();
            assert_eq!(
                ff_ncm_host_set_event_sink(host, Some(receive), user),
                FF_MEDIA_OK
            );
            assert_eq!(
                ff_ncm_host_submit(host, b"{}".as_ptr(), 2),
                FF_MEDIA_ERR_INVALID_ARGUMENT
            );
            let document = serde_json::json!({"requestId":"ffi","accountEpoch":3,
                "route":"/login/qr/create","params":{"key":"fixture"},"cookie":null,
                "deviceId":"A".repeat(52),"budgetMs":15000,"maxResponseBytes":1024})
            .to_string();
            assert_eq!(
                ff_ncm_host_submit(host, document.as_ptr(), document.len()),
                FF_MEDIA_OK
            );
            let event: serde_json::Value =
                serde_json::from_slice(&receiver.recv_timeout(Duration::from_secs(2)).unwrap())
                    .unwrap();
            assert_eq!(event["requestId"], "ffi");
            assert_eq!(event["accountEpoch"], 3);
            assert_eq!(
                ff_ncm_host_set_event_sink(host, None, ptr::null_mut()),
                FF_MEDIA_OK
            );
            assert_eq!(ff_ncm_host_deliveries(host), 1);
            assert_eq!(ff_ncm_host_cancel(host, b"ffi".as_ptr(), 3), FF_MEDIA_OK);
            ff_ncm_host_free(host);
            assert!(receiver.try_recv().is_err());
            ff_ncm_host_free(ptr::null_mut());
        }
    }
}

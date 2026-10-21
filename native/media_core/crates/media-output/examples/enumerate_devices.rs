fn main() {
    let check_stream = std::env::args().any(|argument| argument == "--check-stream");
    let exclusive = std::env::args().any(|argument| argument == "--exclusive");
    let follow_default = std::env::args().any(|argument| argument == "--follow-default");
    println!(
        "{} {}",
        fideflow_media_output::backend(),
        fideflow_media_output::version()
    );
    let context = fideflow_media_output::OutputContext::new().expect("output context");
    for device in context.devices().expect("enumerate") {
        let configuration = fideflow_media_output::OutputConfiguration {
            device_uid: if follow_default {
                None
            } else {
                Some(device.uid.clone())
            },
            exclusive,
            ..fideflow_media_output::OutputConfiguration::default()
        };
        assert!(
            context.route_valid(Some(&device.uid)),
            "device UID must resolve"
        );
        let rate = context.negotiate_rate(&configuration, 44100).expect("rate");
        let channels = context
            .negotiate_channels(&configuration, 2)
            .expect("channels");
        println!(
            "{}: {} default={} exclusive={} rate={} channels={}",
            device.uid, device.name, device.is_default, device.exclusive_supported, rate, channels
        );
        if check_stream {
            if follow_default && !device.is_default {
                continue;
            }
            let output = fideflow_media_output::OutputDevice::start_configured(
                &configuration,
                channels,
                rate,
                512,
                |pcm| pcm.fill(0.0),
            )
            .expect("open silent output");
            std::thread::sleep(std::time::Duration::from_millis(100));
            assert!(output.is_running(), "output must stay running");
            assert_eq!(output.info().device_uid, device.uid);
            if exclusive {
                assert!(output.exclusive_active(), "hog ownership must be verified");
            }
            // The default can disappear under Hog Mode. An already-open stream
            // must still negotiate its PCM against its concrete UID.
            let pinned = fideflow_media_output::OutputConfiguration {
                device_uid: Some(output.info().device_uid.clone()),
                exclusive,
                ..fideflow_media_output::OutputConfiguration::default()
            };
            assert_eq!(
                context.negotiate_rate(&pinned, 44100).expect("pinned rate"),
                rate
            );
            assert_eq!(
                context
                    .negotiate_channels(&pinned, 2)
                    .expect("pinned channels"),
                channels
            );
            println!("  silent output opened and UID verified");
        }
    }
}

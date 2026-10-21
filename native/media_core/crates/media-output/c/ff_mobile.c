/* Mobile PCM device adapter. Decoder, gain and resampling belong to Rust/FFmpeg. */
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#ifdef __ANDROID__
#define MA_ENABLE_AAUDIO
#define MA_ENABLE_OPENSL
#else
#define MA_ENABLE_COREAUDIO
#define MA_NO_RUNTIME_LINKING
#endif
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef __ANDROID__
#import <AVFoundation/AVFoundation.h>

/* CONTROL in Rust serializes this state with device open/close. Retain the
 * session's previous preference so disabling does not impose a fixed 48 kHz. */
static int sample_rate_overridden;
static double previous_preferred_rate;
int ff_output_set_preferred_rate(unsigned int rate) {
    @autoreleasepool {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if(rate == 0 && !sample_rate_overridden) return 0;
        double previous = session.preferredSampleRate;
        double desired = rate ? (double)rate : previous_preferred_rate;
        NSError *error = nil;
        if(previous != desired && ![session setPreferredSampleRate:desired error:&error]) return -1;
        if(rate && !sample_rate_overridden) previous_preferred_rate = previous;
        sample_rate_overridden = rate != 0;
        return 0;
    }
}
#endif
typedef struct { char uid[1024]; char name[256]; int is_default, exclusive_supported; } ff_device_info;
typedef struct { char name[256]; char uid[1024]; int rate, channels, format; unsigned int period, periods; double latency; } ff_output_info;
typedef void (*ff_render_callback)(float *, unsigned int, void *);
typedef struct { ma_device device; ff_render_callback callback; void *user; } ff_output;
static ma_context context;
static unsigned int refs;
static _Atomic unsigned int changes;
static void notify(const ma_device_notification *event) {
    if(event->type == ma_device_notification_type_rerouted) atomic_fetch_or(&changes, 1|2|4);
}
int ff_context_acquire(void) {
    if(refs == 0) {
        ma_context_config config = ma_context_config_init();
#ifndef __ANDROID__
        config.coreaudio.sessionCategory = ma_ios_session_category_none;
        config.coreaudio.noAudioSessionActivate = MA_TRUE;
        config.coreaudio.noAudioSessionDeactivate = MA_TRUE;
#endif
        if(ma_context_init(NULL,0,&config,&context) != MA_SUCCESS) return -1;
    }
    refs++; return 0;
}
void ff_context_release(void) { if(refs && --refs == 0) ma_context_uninit(&context); }
unsigned int ff_output_changes(void) { return atomic_exchange(&changes, 0); }
int ff_output_route_valid(const char *uid) { return !uid || !uid[0] || strcmp(uid,"system-default") == 0; }
int ff_output_default_uid(char *out,size_t size) { if(size < 15) return -1; snprintf(out,size,"system-default"); return 0; }
int ff_output_devices(ff_device_info *out,size_t count) {
    if(!count) return 0;
    memset(out,0,sizeof(*out)); strcpy(out->uid,"system-default"); strcpy(out->name,"System audio output"); out->is_default=1; return 1;
}
unsigned int ff_output_channels(const char *uid,unsigned int preferred,int exclusive) { (void)preferred; return exclusive || !ff_output_route_valid(uid) ? 0 : 2; }
unsigned int ff_output_rate(const char *uid,unsigned int preferred,int exclusive) {
    (void)preferred;
    if(exclusive || !ff_output_route_valid(uid)) return 0;
    /* Probe the current hardware rate before FFmpeg configures its resampler.
     * The probe is never started and owns no Rust callback. */
    ma_device probe;
    ma_device_config config=ma_device_config_init(ma_device_type_playback);
    config.playback.format=ma_format_f32;
    if(ma_device_init(&context,&config,&probe)!=MA_SUCCESS) return 0;
    unsigned int rate=probe.playback.internalSampleRate;
    ma_device_uninit(&probe);
    return rate;
}
static void render(ma_device *device,void *out,const void *in,ma_uint32 frames) {
    (void)in; ff_output *output=device->pUserData;
    if(out) output->callback(out,frames,output->user);
}
int ff_output_start(const char *uid,int exclusive,int rate,int channels,unsigned int period,ff_render_callback callback,void *user,ff_output **out,char *error,size_t size) {
    *out=NULL;
    if(exclusive || !ff_output_route_valid(uid) || !callback || rate<=0 || channels<=0) return -1;
    ff_output *output=calloc(1,sizeof(*output)); if(!output) return -1;
    output->callback=callback; output->user=user;
    ma_device_config config=ma_device_config_init(ma_device_type_playback);
    config.playback.format=ma_format_f32; config.playback.channels=(ma_uint32)channels;
    config.sampleRate=(ma_uint32)rate; config.periodSizeInFrames=period;
    config.dataCallback=render; config.notificationCallback=notify; config.pUserData=output; config.noClip=MA_TRUE;
    ma_result result=ma_device_init(&context,&config,&output->device);
    if(result!=MA_SUCCESS) { snprintf(error,size,"outputDeviceUnavailable: %s",ma_result_description(result)); free(output); return -1; }
    result=ma_device_start(&output->device);
    if(result!=MA_SUCCESS) { snprintf(error,size,"outputDeviceUnavailable: %s",ma_result_description(result)); ma_device_uninit(&output->device); free(output); return -1; }
    *out=output; return 0;
}
int ff_output_get_info(ff_output *output,ff_output_info *info) {
    memset(info,0,sizeof(*info)); strcpy(info->uid,"system-default");
    snprintf(info->name,sizeof(info->name),"%s",output->device.playback.name);
    info->rate=(int)output->device.playback.internalSampleRate; info->channels=(int)output->device.playback.internalChannels;
    info->format=(int)output->device.playback.internalFormat; info->period=output->device.playback.internalPeriodSizeInFrames;
    info->periods=output->device.playback.internalPeriods; info->latency= info->rate ? (double)info->period/info->rate : 0; return 0;
}
int ff_output_is_running(ff_output *output) { return ma_device_is_started(&output->device); }
int ff_output_hog_owned(ff_output *output) { (void)output; return 0; }
void ff_output_pause(ff_output *output) { ma_device_stop(&output->device); }
int ff_output_resume(ff_output *output) { return ma_device_start(&output->device)==MA_SUCCESS ? 0 : -1; }
void ff_output_release(ff_output *output) { ma_device_uninit(&output->device); free(output); }

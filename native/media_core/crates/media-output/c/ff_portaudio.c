/* PortAudio transport, Core Audio device policy. No allocation or locks in render. */
#include <portaudio.h>
#include <pa_mac_core.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stddef.h>

#define FF_UID_BYTES 1024
#define FF_NAME_BYTES 256
#define FF_LIST_CHANGED 1u
#define FF_DEFAULT_CHANGED 2u
extern AudioDeviceID ff_pa_device_id(PaDeviceIndex index);
typedef void (*ff_render_callback)(float *, unsigned int, void *);
typedef struct { char uid[FF_UID_BYTES]; char name[FF_NAME_BYTES]; int is_default; int exclusive_supported; } ff_device_info;
typedef struct { char device_name[FF_NAME_BYTES]; char device_uid[FF_UID_BYTES]; int sample_rate, channels, internal_format; unsigned int period_frames, periods; double period_seconds; } ff_output_info;
typedef struct { PaStream *stream; AudioDeviceID device; ff_render_callback callback; void *user; int channels; unsigned int period; int hog; int required_exclusive; uint64_t listener_token; unsigned int listener_count; int changed_rate; Float64 old_rate, configured_rate; } ff_output;
/* Fixed listener slots outlive every device. Tokens prevent delayed callbacks
 * from observing freed output state or faulting a subsequently opened stream. */
static _Atomic uint64_t device_state[64];
static _Atomic unsigned int changes;
static uint64_t next_listener_token;
static const AudioObjectPropertySelector watched[] = {kAudioDevicePropertyDeviceIsAlive,kAudioDevicePropertyIOStoppedAbnormally,kAudioDevicePropertyNominalSampleRate,kAudioDevicePropertyHogMode};
static OSStatus device_changed(AudioObjectID object, UInt32 count,const AudioObjectPropertyAddress *addresses,void *user) {
    (void)object;
    uint64_t token=(uint64_t)(uintptr_t)user;
    uint64_t flags=1;
    for(UInt32 i=0;i<count;i++) {
        if(addresses[i].mSelector==kAudioDevicePropertyIOStoppedAbnormally)flags|=2;
        if(addresses[i].mSelector==kAudioDevicePropertyNominalSampleRate)atomic_fetch_or(&changes,4);
    }
    uint64_t expected=atomic_load(&device_state[token & 63]);
    while((expected>>2)==token && !atomic_compare_exchange_weak(&device_state[token & 63],&expected,expected|flags)){}
    return noErr;
}
static int watch_device(ff_output *output) {
    for(unsigned int i=0;i<64;i++) {
        uint64_t token=++next_listener_token;
        if(atomic_load(&device_state[token & 63])==0){output->listener_token=token;atomic_store(&device_state[token & 63],token<<2);break;}
    }
    if(!output->listener_token)return 0;
    for(unsigned int i=0;i<sizeof(watched)/sizeof(watched[0]);i++) {
        AudioObjectPropertyAddress addr={watched[i],kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        if(AudioObjectHasProperty(output->device,&addr) && AudioObjectAddPropertyListener(output->device,&addr,device_changed,(void *)(uintptr_t)output->listener_token)!=noErr)return 0;
        output->listener_count++;
    }
    return 1;
}
static void unwatch_device(ff_output *output) {
    if(!output->listener_token)return;
    atomic_store(&device_state[output->listener_token & 63],0);
    for(unsigned int i=0;i<output->listener_count;i++) {
        AudioObjectPropertyAddress addr={watched[i],kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        AudioObjectRemovePropertyListener(output->device,&addr,device_changed,(void *)(uintptr_t)output->listener_token);
    }
    output->listener_token=0;
}
static unsigned int refs, streams;
static int initialized;
static AudioObjectPropertyAddress device_list = {kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
static AudioObjectPropertyAddress default_output = {kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
static OSStatus changed(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *props, void *user) {
    (void)object; (void)user;
    unsigned int flags=0;
    for(UInt32 i=0;i<count;i++) flags |= props[i].mSelector==kAudioHardwarePropertyDefaultOutputDevice ? FF_DEFAULT_CHANGED : FF_LIST_CHANGED;
    atomic_fetch_or(&changes,flags); return noErr;
}
static int get(AudioObjectID object, AudioObjectPropertySelector selector, void *value, UInt32 size) {
    AudioObjectPropertyAddress addr={selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object,&addr,0,NULL,&size,value)==noErr;
}
static int set(AudioObjectID object, AudioObjectPropertySelector selector, const void *value, UInt32 size) {
    AudioObjectPropertyAddress addr={selector,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    return AudioObjectSetPropertyData(object,&addr,0,NULL,size,value)==noErr;
}
static int cf_text(AudioObjectID device, AudioObjectPropertySelector property, char *text, size_t size) {
    CFStringRef value=NULL;
    if(!get(device,property,&value,sizeof(value)) || !value) return 0;
    int ok=CFStringGetCString(value,text,(CFIndex)size,kCFStringEncodingUTF8); CFRelease(value); return ok;
}
static AudioDeviceID current_default(void) {
    AudioDeviceID value=kAudioObjectUnknown;
    get(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultOutputDevice,&value,sizeof(value)); return value;
}
static AudioDeviceID resolve(const char *uid) {
    if(!uid || !uid[0]) return current_default();
    CFStringRef text=CFStringCreateWithCString(NULL,uid,kCFStringEncodingUTF8);
    if(!text) return kAudioObjectUnknown;
    AudioDeviceID device=kAudioObjectUnknown;
    /* AudioObject API takes the UID as qualifier data, unlike the legacy
     * AudioHardware API's AudioValueTranslation payload. */
    AudioObjectPropertyAddress addr={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=sizeof(device);
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&addr,sizeof(text),&text,&size,&device)!=noErr)
        device=kAudioObjectUnknown;
    CFRelease(text); return device;
}
int ff_context_acquire(void) {
    if(refs++) return 0;
    if(Pa_Initialize()!=paNoError) {refs=0;return -1;}
    initialized=1;
    if(AudioObjectAddPropertyListener(kAudioObjectSystemObject,&device_list,changed,NULL)!=noErr) goto fail;
    if(AudioObjectAddPropertyListener(kAudioObjectSystemObject,&default_output,changed,NULL)!=noErr) {
        AudioObjectRemovePropertyListener(kAudioObjectSystemObject,&device_list,changed,NULL); goto fail;
    }
    atomic_store(&changes,0); return 0;
fail:
    Pa_Terminate(); initialized=0;refs=0; return -1;
}
void ff_context_release(void) {
    if(!refs || --refs) return;
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject,&device_list,changed,NULL);
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject,&default_output,changed,NULL);
    if(initialized) Pa_Terminate(); initialized=0;
}
unsigned int ff_output_changes(void) { return atomic_exchange(&changes,0); }
/* PA's device cache is rebuilt only when opening a stream with no live streams.
 * Selector refresh reads HAL directly and never terminates active transport. */
static int refresh_transport(void) {
    if(streams) return 0;
    if(initialized && Pa_Terminate()!=paNoError) return -1;
    initialized=0;
    if(Pa_Initialize()!=paNoError) return -1;
    initialized=1; return 0;
}
static unsigned int output_channels(AudioDeviceID device) {
    AudioObjectPropertyAddress addr={kAudioDevicePropertyStreamConfiguration,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(device,&addr,0,NULL,&size)!=noErr || size<sizeof(UInt32) || size>65536)return 0;
    AudioBufferList *buffers=malloc(size);
    if(!buffers)return 0;
    unsigned int channels=0;
    if(AudioObjectGetPropertyData(device,&addr,0,NULL,&size,buffers)==noErr) {
        size_t header=offsetof(AudioBufferList,mBuffers);
        if(size>=header && buffers->mNumberBuffers<=(size-header)/sizeof(AudioBuffer))
            for(UInt32 i=0;i<buffers->mNumberBuffers;i++)channels+=buffers->mBuffers[i].mNumberChannels;
    }
    free(buffers); return channels;
}
int ff_output_devices(ff_device_info *buffer, size_t capacity) {
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&device_list,0,NULL,&size)!=noErr || size>65536)return -1;
    if(!size)return 0;
    AudioDeviceID *devices=malloc(size);
    if(!devices)return -1;
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&device_list,0,NULL,&size,devices)!=noErr){free(devices);return -1;}
    int written=0;
    AudioDeviceID system_default=current_default();
    for(UInt32 i=0;i<size/sizeof(*devices);i++) {
        AudioDeviceID id=devices[i];
        if(!output_channels(id))continue;
        if((size_t)written>=capacity){free(devices);return -1;}
        ff_device_info *out=&buffer[written]; memset(out,0,sizeof(*out));
        if(!cf_text(id,kAudioDevicePropertyDeviceUID,out->uid,sizeof(out->uid)) ||
           !cf_text(id,kAudioObjectPropertyName,out->name,sizeof(out->name))){free(devices);return -1;}
        out->is_default=id==system_default;
        Boolean writable=false;
        AudioObjectPropertyAddress addr={kAudioDevicePropertyHogMode,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        out->exclusive_supported=AudioObjectIsPropertySettable(id,&addr,&writable)==noErr && writable;
        written++;
    }
    free(devices);return written;
}
int ff_output_route_valid(const char *uid) {
    AudioDeviceID id=resolve(uid); UInt32 alive=0;
    return id && get(id,kAudioDevicePropertyDeviceIsAlive,&alive,sizeof(alive)) && alive;
}
int ff_output_default_uid(char *text, size_t size) { return cf_text(current_default(),kAudioDevicePropertyDeviceUID,text,size) ? 0:-1; }
/* Rate negotiation never changes device state. Actual rate changes happen after hog acquisition. */
unsigned int ff_output_rate(const char *uid, unsigned int preferred, int exclusive) {
    AudioDeviceID id=resolve(uid); Float64 nominal=48000;
    if(!id || !get(id,kAudioDevicePropertyNominalSampleRate,&nominal,sizeof(nominal))) return 0;
    if(exclusive && preferred>=8000 && preferred<=384000) {
        AudioObjectPropertyAddress addr={kAudioDevicePropertyAvailableNominalSampleRates,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        UInt32 size=0;
        if(AudioObjectGetPropertyDataSize(id,&addr,0,NULL,&size)==noErr && size<=65536) {
            AudioValueRange *ranges=malloc(size);
            if(ranges && AudioObjectGetPropertyData(id,&addr,0,NULL,&size,ranges)==noErr) {
                for(UInt32 i=0;i<size/sizeof(*ranges);i++) if(preferred>=ranges[i].mMinimum && preferred<=ranges[i].mMaximum) {free(ranges);return preferred;}
            }
            free(ranges);
        }
    }
    return (unsigned int)nominal;
}
static int render(const void *input, void *output, unsigned long frames, const PaStreamCallbackTimeInfo *time, PaStreamCallbackFlags flags, void *user) {
    (void)input; (void)time; (void)flags;
    ff_output *context=user;
    if(output) context->callback(output,(unsigned int)frames,context->user);
    return paContinue;
}
static void release_hog(ff_output *output) {
    if(!output->hog) return;
    pid_t owner=-1;
    if(get(output->device,kAudioDevicePropertyHogMode,&owner,sizeof(owner)) && owner==getpid()) {
        Float64 current=0;
        if(output->changed_rate && get(output->device,kAudioDevicePropertyNominalSampleRate,&current,sizeof(current)) && current==output->configured_rate)
            set(output->device,kAudioDevicePropertyNominalSampleRate,&output->old_rate,sizeof(output->old_rate));
        set(output->device,kAudioDevicePropertyHogMode,&owner,sizeof(owner));
    }
    output->hog=0;
}
void ff_output_release(ff_output *output) {
    if(!output) return;
    unwatch_device(output);
    if(output->stream) {Pa_StopStream(output->stream);Pa_CloseStream(output->stream);streams--;}
    release_hog(output); free(output);
}
int ff_output_start(const char *uid, int exclusive, int sample_rate, int channels, unsigned int period,
    ff_render_callback callback, void *user, ff_output **out, char *error, size_t error_size) {
    *out=NULL;
    if(refresh_transport()!=0){snprintf(error,error_size,"outputOpenFailed");return -1;}
    AudioDeviceID device=resolve(uid);
    if(!device || !ff_output_route_valid(uid)) {snprintf(error,error_size,"outputDeviceUnavailable");return -1;}
    ff_output *context=calloc(1,sizeof(*context));
    if(!context) return -1;
    context->device=device;context->required_exclusive=exclusive;context->channels=channels;context->period=period;context->callback=callback;context->user=user;
    const char *failure="outputOpenFailed";
    if(exclusive) {
        failure="outputExclusiveUnavailable";
        pid_t owner=-1;
        if(!get(device,kAudioDevicePropertyHogMode,&owner,sizeof(owner)) || owner!=-1) goto fail;
        if(!set(device,kAudioDevicePropertyHogMode,&owner,sizeof(owner))) goto fail;
        context->hog=1;
        if(!get(device,kAudioDevicePropertyHogMode,&owner,sizeof(owner)) || owner!=getpid()) goto fail;
        if(!get(device,kAudioDevicePropertyNominalSampleRate,&context->old_rate,sizeof(context->old_rate))) goto fail;
        context->configured_rate=sample_rate;
        if(context->old_rate!=sample_rate) {
            context->changed_rate=1;
            if(!set(device,kAudioDevicePropertyNominalSampleRate,&context->configured_rate,sizeof(context->configured_rate))) goto fail;
        }
    }
    failure="outputOpenFailed";
    PaDeviceIndex index=paNoDevice;
    for(int i=0;i<Pa_GetDeviceCount();i++) if(ff_pa_device_id(i)==device && Pa_GetDeviceInfo(i)->maxOutputChannels>=channels) {index=i;break;}
    if(index==paNoDevice) goto fail;
    PaMacCoreStreamInfo core;
    PaMacCore_SetupStreamInfo(&core,exclusive ? paMacCoreChangeDeviceParameters|paMacCoreFailIfConversionRequired:paMacCorePlayNice);
    PaStreamParameters parameters={index,channels,paFloat32,Pa_GetDeviceInfo(index)->defaultLowOutputLatency,&core};
    PaError result=Pa_OpenStream(&context->stream,NULL,&parameters,sample_rate,period,paDitherOff|paClipOff,render,context);
    if(result!=paNoError) {context->stream=NULL;goto fail;}
    streams++;
    if(PaMacCore_GetStreamOutputDevice(context->stream)!=device) goto fail;
    if(exclusive) {
        Float64 actual=0;
        if(!get(device,kAudioDevicePropertyNominalSampleRate,&actual,sizeof(actual)) || actual!=sample_rate) goto fail;
    }
    if(Pa_StartStream(context->stream)!=paNoError) goto fail;
    if(!watch_device(context))goto fail;
    *out=context; return 0;
fail:
    snprintf(error,error_size,"%s",failure);ff_output_release(context);return -1;
}
int ff_output_is_running(const ff_output *output) {return output && Pa_IsStreamActive(output->stream)==1 && (atomic_load(&device_state[output->listener_token & 63])>>2)==output->listener_token && !(atomic_load(&device_state[output->listener_token & 63])&2);}
int ff_output_hog_owned(const ff_output *output) {pid_t owner=-1;Float64 rate=0;return output && output->hog && get(output->device,kAudioDevicePropertyHogMode,&owner,sizeof(owner)) && owner==getpid() && get(output->device,kAudioDevicePropertyNominalSampleRate,&rate,sizeof(rate)) && rate==output->configured_rate;}
int ff_output_get_info(const ff_output *output, ff_output_info *info) {
    if(!output || !info) return -1;
    memset(info,0,sizeof(*info));cf_text(output->device,kAudioObjectPropertyName,info->device_name,sizeof(info->device_name));cf_text(output->device,kAudioDevicePropertyDeviceUID,info->device_uid,sizeof(info->device_uid));
    const PaStreamInfo *stream=Pa_GetStreamInfo(output->stream);if(!stream)return -1;
    info->sample_rate=(int)stream->sampleRate;info->channels=output->channels;info->internal_format=1;info->period_frames=output->period;info->periods=1;info->period_seconds=stream->outputLatency;return 0;
}
void ff_output_pause(ff_output *output) {if(output){Pa_AbortStream(output->stream);release_hog(output);}}
int ff_output_resume(ff_output *output) {if(!output || output->required_exclusive)return -1;return Pa_StartStream(output->stream)==paNoError?0:-1;}
unsigned int ff_output_channels(const char *uid, unsigned int preferred, int exclusive) {
    unsigned int maximum=output_channels(resolve(uid));
    if(exclusive && preferred>=1 && preferred<=8 && preferred<=maximum)return preferred;
    return maximum>=2?2:(maximum==1?1:0);
}

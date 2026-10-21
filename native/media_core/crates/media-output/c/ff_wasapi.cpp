// WASAPI device policy behind the same scalar/opaque boundary as Core Audio.
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <mmreg.h>
#include <functiondiscoverykeys_devpkey.h>
#include <portaudio.h>
#include <pa_win_wasapi.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>

struct ff_device_info { char uid[1024], name[256]; int is_default, exclusive_supported; };
struct ff_output_info { char name[256], uid[1024]; int rate, channels, format; unsigned period, periods; double latency; };
using Render = void (*)(float*, unsigned, void*);
struct Output { PaStream* stream = nullptr; Render render; void* user; int channels; unsigned period; bool exclusive; char uid[1024], name[256]; };
static IMMDeviceEnumerator* enumerator;
static CO_MTA_USAGE_COOKIE mta;
static unsigned refs, streams;
static std::atomic<unsigned> changes{0};

class Notifications final : public IMMNotificationClient {
    std::atomic<ULONG> refs_{1};
public:
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id == __uuidof(IUnknown) || id == __uuidof(IMMNotificationClient)) { *out = this; AddRef(); return S_OK; }
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override { auto n = --refs_; if (!n) delete this; return n; }
    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { changes.fetch_or(1); return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { changes.fetch_or(1); return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { changes.fetch_or(1); return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
        if (flow == eRender && role == eConsole) changes.fetch_or(2);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { changes.fetch_or(1|4); return S_OK; }
};
static Notifications* notifications;
static bool text(LPCWSTR value, char* out, size_t size) {
    return value && size <= INT_MAX && WideCharToMultiByte(CP_UTF8, 0, value, -1, out, static_cast<int>(size), nullptr, nullptr) > 0;
}
static IMMDevice* resolve(const char* uid) {
    if (!enumerator) return nullptr;
    IMMDevice* device = nullptr;
    if (!uid || !*uid) {
        enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    } else {
        int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, uid, -1, nullptr, 0);
        if (count <= 0) return nullptr;
        std::wstring value(static_cast<size_t>(count), L'\0');
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, uid, -1, value.data(), count);
        enumerator->GetDevice(value.c_str(), &device);
    }
    return device;
}
static bool identity(IMMDevice* device, char* uid, size_t size) {
    LPWSTR id = nullptr;
    if (FAILED(device->GetId(&id))) return false;
    bool ok = text(id, uid, size); CoTaskMemFree(id); return ok;
}
static void device_name(IMMDevice* device, char* out, size_t size) {
    IPropertyStore* properties = nullptr;
    if (FAILED(device->OpenPropertyStore(STGM_READ, &properties))) return;
    PROPVARIANT value{};
    if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &value)) && value.vt == VT_LPWSTR) text(value.pwszVal, out, size);
    PropVariantClear(&value); properties->Release();
}
static PaDeviceIndex pa_device(const char* uid) {
    char target[1024]{};
    IMMDevice* device = resolve(uid);
    if (!device) return paNoDevice;
    bool found = identity(device, target, sizeof(target)); device->Release();
    if (!found) return paNoDevice;
    for (int i = 0; i < Pa_GetDeviceCount(); ++i) {
        const PaDeviceInfo* info = Pa_GetDeviceInfo(i);
        if (!info || !info->maxOutputChannels || Pa_GetHostApiInfo(info->hostApi)->type != paWASAPI) continue;
        void* raw = nullptr;
        char candidate[1024]{};
        if (PaWasapi_GetIMMDevice(i, &raw) == paNoError && raw && identity(static_cast<IMMDevice*>(raw), candidate, sizeof(candidate)) && !strcmp(target, candidate)) return i;
    }
    return paNoDevice;
}
extern "C" {
int ff_context_acquire() {
    if (refs++) return 0;
    if (FAILED(CoIncrementMTAUsage(&mta))) { refs = 0; return -1; }
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&enumerator));
    if (FAILED(hr) || Pa_Initialize() != paNoError) {
        if (enumerator) { enumerator->Release(); enumerator = nullptr; }
        CoDecrementMTAUsage(mta); refs = 0; return -1;
    }
    notifications = new Notifications();
    if (FAILED(enumerator->RegisterEndpointNotificationCallback(notifications))) {
        notifications->Release(); notifications = nullptr;
        Pa_Terminate(); enumerator->Release(); enumerator = nullptr; CoDecrementMTAUsage(mta); refs = 0; return -1;
    }
    return 0;
}
void ff_context_release() {
    if (!refs || --refs) return;
    enumerator->UnregisterEndpointNotificationCallback(notifications);
    notifications->Release(); notifications = nullptr;
    Pa_Terminate(); enumerator->Release(); enumerator = nullptr; CoDecrementMTAUsage(mta);
}
unsigned ff_output_changes() { return changes.exchange(0); }
int ff_output_default_uid(char* out, size_t size) {
    auto device = resolve(nullptr); if (!device) return -1;
    bool ok = identity(device, out, size); device->Release(); return ok ? 0 : -1;
}
int ff_output_route_valid(const char* uid) {
    auto device = resolve(uid); if (!device) return 0;
    DWORD state = 0; bool ok = SUCCEEDED(device->GetState(&state)) && state == DEVICE_STATE_ACTIVE;
    device->Release(); return ok;
}
int ff_output_devices(ff_device_info* out, size_t capacity) {
    if (!enumerator) return -1;
    IMMDeviceCollection* list = nullptr;
    if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &list))) return -1;
    UINT count = 0; list->GetCount(&count);
    if (count > capacity) { list->Release(); return -1; }
    char default_uid[1024]{}; ff_output_default_uid(default_uid, sizeof(default_uid));
    for (UINT i = 0; i < count; ++i) {
        IMMDevice* device = nullptr;
        if (FAILED(list->Item(i, &device))) { list->Release(); return -1; }
        memset(&out[i], 0, sizeof(out[i]));
        bool ok = identity(device, out[i].uid, sizeof(out[i].uid));
        device_name(device, out[i].name, sizeof(out[i].name)); device->Release();
        if (!ok) { list->Release(); return -1; }
        out[i].is_default = !strcmp(default_uid, out[i].uid);
        out[i].exclusive_supported = 1; // Actual format/access checked on opening.
    }
    list->Release(); return static_cast<int>(count);
}
static bool refresh() {
    if (streams) return true;
    return Pa_Terminate() == paNoError && Pa_Initialize() == paNoError;
}
unsigned ff_output_channels(const char* uid, unsigned preferred, int exclusive) {
    if (!refresh()) return 0;
    auto index = pa_device(uid); if (index == paNoDevice) return 0;
    auto info = Pa_GetDeviceInfo(index);
    if (exclusive && preferred >= 1 && preferred <= 8 && preferred <= static_cast<unsigned>(info->maxOutputChannels)) return preferred;
    return info->maxOutputChannels >= 2 ? 2 : 1;
}
unsigned ff_output_rate(const char* uid, unsigned preferred, int exclusive) {
    if (!refresh()) return 0;
    auto index = pa_device(uid); if (index == paNoDevice) return 0;
    if (exclusive && preferred >= 8000 && preferred <= 384000) return preferred;
    // PortAudio caches its device mix format while a stream is open. Read the
    // endpoint directly so an OS format-change notification sees the new rate.
    auto device = resolve(uid); if (!device) return 0;
    IAudioClient* client = nullptr;
    HRESULT result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&client));
    device->Release();
    if (FAILED(result)) return 0;
    WAVEFORMATEX* format = nullptr;
    result = client->GetMixFormat(&format);
    unsigned rate = SUCCEEDED(result) && format ? format->nSamplesPerSec : 0;
    CoTaskMemFree(format); client->Release();
    return rate;
}
static int callback(const void*, void* pcm, unsigned long frames, const PaStreamCallbackTimeInfo*, PaStreamCallbackFlags, void* user) {
    auto output = static_cast<Output*>(user);
    if (pcm) output->render(static_cast<float*>(pcm), static_cast<unsigned>(frames), output->user);
    return paContinue;
}
void ff_output_release(Output* output) {
    if (!output) return;
    if (output->stream) { Pa_AbortStream(output->stream); Pa_CloseStream(output->stream); --streams; }
    delete output;
}
int ff_output_start(const char* uid, int exclusive, int rate, int channels, unsigned period, Render render, void* user, Output** out, char* error, size_t size) {
    *out = nullptr;
    if (!refresh()) { snprintf(error, size, "outputOpenFailed"); return -1; }
    auto index = pa_device(uid);
    if (index == paNoDevice) { snprintf(error, size, "outputDeviceUnavailable"); return -1; }
    auto output = new Output();
    output->render = render; output->user = user; output->channels = channels; output->period = period; output->exclusive = exclusive != 0;
    auto device = resolve(uid);
    if (!device) { delete output; return -1; }
    identity(device, output->uid, sizeof(output->uid)); device_name(device, output->name, sizeof(output->name)); device->Release();
    PaWasapiStreamInfo wasapi{}; wasapi.size = sizeof(wasapi); wasapi.hostApiType = paWASAPI; wasapi.version = 1;
    // Shared endpoints may mix in 5.1/7.1 even though our PCM is stereo.
    // Let WASAPI convert channel layouts; exclusive output keeps its exact format.
    wasapi.flags = exclusive ? paWinWasapiExclusive : paWinWasapiAutoConvert;
    PaStreamParameters parameters{index, channels, paFloat32, Pa_GetDeviceInfo(index)->defaultLowOutputLatency, &wasapi};
    PaError result = Pa_OpenStream(&output->stream, nullptr, &parameters, rate, period, paDitherOff | paClipOff, callback, output);
    if (result != paNoError) output->stream = nullptr;
    if (result == paNoError) {
        ++streams;
        result = Pa_StartStream(output->stream);
    }
    if (result != paNoError) {
        snprintf(error, size, "%s", exclusive ? "outputExclusiveUnavailable" : "outputOpenFailed");
        ff_output_release(output); return -1;
    }
    *out = output; return 0;
}
int ff_output_get_info(const Output* output, ff_output_info* out) {
    if (!output || !out) return -1;
    const auto info = Pa_GetStreamInfo(output->stream); if (!info) return -1;
    memset(out, 0, sizeof(*out)); memcpy(out->name, output->name, sizeof(out->name)); memcpy(out->uid, output->uid, sizeof(out->uid));
    out->rate = static_cast<int>(info->sampleRate); out->channels = output->channels; out->format = 1;
    out->period = output->period; out->periods = 1; out->latency = info->outputLatency; return 0;
}
int ff_output_is_running(const Output* output) { return output && Pa_IsStreamActive(output->stream) == 1 && ff_output_route_valid(output->uid); }
int ff_output_hog_owned(const Output* output) { return output && output->exclusive && ff_output_is_running(output); }
void ff_output_pause(Output* output) { if (output) Pa_AbortStream(output->stream); }
int ff_output_resume(Output* output) { return output && !output->exclusive && Pa_StartStream(output->stream) == paNoError ? 0 : -1; }
}

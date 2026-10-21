
/* Fideflow extension: resolve a global PA index to its actual HAL device.
 * Avoid name/order-based mapping. Compiled onto the pinned backend, not applied
 * to the upstream source tree. */
AudioDeviceID ff_pa_device_id(PaDeviceIndex device) {
    PaUtilHostApiRepresentation *api = NULL;
    PaDeviceIndex hostIndex;
    if (PaUtil_GetHostApiRepresentation(&api, paCoreAudio) != paNoError ||
        PaUtil_DeviceIndexToHostApiDeviceIndex(&hostIndex, device, api) != paNoError)
        return kAudioObjectUnknown;
    return ((PaMacAUHAL *)api)->devIds[hostIndex];
}

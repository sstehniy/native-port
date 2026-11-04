#include "com.h"
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <mutex>

namespace {
constexpr uint32_t POINTER = 0x80004003, INVALID = 0x80070057, NO_INTERFACE = 0x80004002;
constexpr uint32_t NOT_FOUND = 0x80070490, NOT_IMPL = 0x80004001, ACCESS = 0x80070005;
constexpr uint32_t NOT_INITIALIZED = 0x88890001, ALREADY_INITIALIZED = 0x88890002;
constexpr uint32_t BUFFER_TOO_LARGE = 0x88890006, OUT_OF_ORDER = 0x88890007, UNSUPPORTED = 0x88890008, INVALID_SIZE = 0x88890009;
constexpr uint32_t DEVICE_INVALIDATED = 0x88890004, NOT_STOPPED = 0x88890005, EVENT_NOT_SET = 0x88890014;
constexpr uint32_t EVENT_CALLBACK = 0x40000;
constexpr RtGuid ENUM_CLASS = {0xbcde0395,0xe52f,0x467c,{0x8e,0x3d,0xc4,0x57,0x92,0x91,0x69,0x2e}};
constexpr RtGuid ENUM_IID = {0xa95664d2,0x9614,0x4f35,{0xa7,0x46,0xde,0x8d,0xb6,0x36,0x17,0xe6}};
constexpr RtGuid DEVICE_IID = {0xd666063f,0x1587,0x4e43,{0x81,0xf1,0xb9,0x48,0xe8,0x07,0x36,0x3f}};
constexpr RtGuid ENDPOINT_IID = {0x1be09788,0x6894,0x4089,{0x85,0x86,0x9a,0x2a,0x6c,0x26,0x5a,0xc5}};
constexpr RtGuid COLLECTION_IID = {0x0bd7a1be,0x7a1a,0x44db,{0x83,0x97,0xcc,0x53,0x92,0x38,0x7b,0x5e}};
constexpr RtGuid PROPERTY_IID = {0x886d8eeb,0x8cf2,0x4446,{0x8d,0x02,0xcd,0xba,0x1d,0xbd,0xcf,0x99}};
constexpr RtGuid CLIENT_IID = {0x1cb9ad4c,0xdbfa,0x4c32,{0xb1,0x78,0xc2,0xf5,0x68,0xa7,0x03,0xb2}};
constexpr RtGuid RENDER_IID = {0xf294acfc,0x3146,0x4483,{0xa7,0xbf,0xad,0xdc,0xa7,0xc2,0x60,0xe2}};
constexpr RtGuid CLOCK_IID = {0xcd63314f,0x3fba,0x4a1b,{0x81,0x2c,0xef,0x96,0x35,0x87,0x28,0xe7}};
constexpr RtGuid PCM = {1,0,0x10,{0x80,0,0,0xaa,0,0x38,0x9b,0x71}};
constexpr RtGuid FLOAT = {3,0,0x10,{0x80,0,0,0xaa,0,0x38,0x9b,0x71}};
struct PropertyKey { RtGuid guid; uint32_t id; bool operator==(const PropertyKey &) const = default; };
constexpr PropertyKey NAME = {{0xa45c254e,0xdf1c,0x4efd,{0x80,0x20,0x67,0xd1,0x46,0xa8,0x50,0xe0}},14};
constexpr PropertyKey FORMAT = {{0xf19f064d,0x082c,0x4e27,{0xbc,0x73,0x68,0x82,0xa1,0xbb,0x8e,0x4c}},0};
constexpr PropertyKey SPEAKERS = {{0x1da5d803,0xd492,0x4edd,{0x8c,0x23,0xe0,0xc0,0xff,0xee,0x7f,0x0e}},3};
constexpr std::array PROPERTY_KEYS = {NAME, FORMAT, SPEAKERS};
#pragma pack(push,1)
struct WaveFormat {
    uint16_t tag, channels;
    uint32_t rate, bytes_per_second;
    uint16_t alignment, bits, extra;
};
struct WaveExt { WaveFormat base; uint16_t valid_bits; uint32_t mask; RtGuid subtype; };
#pragma pack(pop)
static_assert(sizeof(WaveFormat)==18 && sizeof(WaveExt)==40 && sizeof(PropertyKey)==20);

struct DeviceInfo {
    AudioDeviceID native = kAudioObjectUnknown;
    uint32_t rate = 48000;
    std::u16string id, name;
};
DeviceInfo default_device() {
    DeviceInfo result;
    AudioObjectPropertyAddress property{kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=sizeof(result.native);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,&property,0,nullptr,&size,&result.native) || !result.native) return result;
    property={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    double rate=0;size=sizeof(rate);
    if (!AudioObjectGetPropertyData(result.native,&property,0,nullptr,&size,&rate) && rate>=8000 && rate<=192000) result.rate=(uint32_t)llround(rate);
    property={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    CFStringRef name=nullptr;size=sizeof(name);
    if (!AudioObjectGetPropertyData(result.native,&property,0,nullptr,&size,&name) && name) {
        char text[1024];
        if (CFStringGetCString(name,text,sizeof(text),kCFStringEncodingUTF8)) result.name=rt_utf16(text);
        CFRelease(name);
    }
    if (result.name.empty()) result.name=u"Core Audio default output";
    result.id=rt_utf16("SS_CoreAudio_"+std::to_string(result.native));
    return result;
}
WaveExt mix_format(const DeviceInfo &device) {
    return {{0xfffe,2,device.rate,device.rate*8,8,32,22},32,3,FLOAT};
}
void *copy_memory(const void *data,size_t size) { void *result=rt_alloc(size,false);memcpy(result,data,size);return result; }
void *copy_string(const std::u16string &text) { return copy_memory(text.c_str(),(text.size()+1)*2); }
uint32_t give(RtComObject *object,const RtGuid &iid,void *out) {
    void *pointer=nullptr;const uint32_t result=object->query(iid,&pointer);object->release();
    rt_put<uint64_t>(out,(uintptr_t)pointer);return result;
}
template<class T> T *owner(WinCall *c) { return static_cast<T *>(((RtComInterface *)(uintptr_t)A(0))->object); }

class AudioClient final : public RtComObject {
public:
    AudioClient(const DeviceInfo &device,std::initializer_list<RtComInterfaceSpec> specs):RtComObject(specs),device(device) {}
    DeviceInfo device;
    WaveFormat format{};
    AudioUnit unit=nullptr;
    uint32_t capacity=0, pending=0, flags=0;
    std::vector<uint8_t> ring, scratch;
    std::atomic<uint64_t> written{0},read{0},clock{0},callbacks{0},underrun_frames{0},submitted{0},consumed{0};
    std::atomic<bool> running{false};
    uint64_t event=0;
    dispatch_queue_t notifications=nullptr;
    dispatch_source_t notification=nullptr;
    ~AudioClient() override {
        running=false;
        if (unit) { AudioOutputUnitStop(unit);AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit); }
        if (notification) { dispatch_source_cancel(notification);dispatch_sync(notifications,^{}); }
        if (capacity) fprintf(stderr,"audio: closed %u Hz, %u channels; %llu submitted, %llu consumed, %llu callbacks, %llu underrun frames\n",format.rate,format.channels,(unsigned long long)submitted.load(),(unsigned long long)consumed.load(),(unsigned long long)callbacks.load(),(unsigned long long)underrun_frames.load());
    }
    uint64_t padding() const { return written.load(std::memory_order_acquire)-read.load(std::memory_order_acquire); }
    static OSStatus render(void *context,AudioUnitRenderActionFlags *,const AudioTimeStamp *,UInt32,UInt32 frames,AudioBufferList *data) {
        auto &client=*static_cast<AudioClient *>(context);
        if (data->mNumberBuffers!=1) return kAudio_ParamError;
        const size_t bytes=(size_t)frames*client.format.alignment;
        if (data->mBuffers[0].mDataByteSize<bytes || !data->mBuffers[0].mData) return kAudio_ParamError;
        auto *output=static_cast<uint8_t *>(data->mBuffers[0].mData);
        memset(output,0,bytes);data->mBuffers[0].mDataByteSize=(UInt32)bytes;
        if (!client.running.load(std::memory_order_acquire)) return noErr;
        const uint64_t tail=client.read.load(std::memory_order_relaxed),head=client.written.load(std::memory_order_acquire);
        const uint32_t count=(uint32_t)std::min<uint64_t>(frames,head-tail),offset=(uint32_t)(tail%client.capacity);
        const uint32_t first=std::min(count,client.capacity-offset);
        memcpy(output,client.ring.data()+(size_t)offset*client.format.alignment,(size_t)first*client.format.alignment);
        memcpy(output+(size_t)first*client.format.alignment,client.ring.data(),(size_t)(count-first)*client.format.alignment);
        client.read.store(tail+count,std::memory_order_release);client.clock.fetch_add(frames,std::memory_order_relaxed);client.consumed.fetch_add(count,std::memory_order_relaxed);
        client.callbacks.fetch_add(1,std::memory_order_relaxed);client.underrun_frames.fetch_add(frames-count,std::memory_order_relaxed);
        // Wake the guest off the real-time render thread; it may acquire the Win32 wait lock.
        if (client.notification) dispatch_source_merge_data(client.notification,1);
        return noErr;
    }
};
H(ClientInitialize) {
    auto *client=owner<AudioClient>(c);
    if (client->capacity) return ALREADY_INITIALIZED;
    if (!P(5)) return POINTER;
    if (A(1)!=0) return 0x8889000e; // Exclusive mode is not exposed by this shared endpoint.
    const uint32_t flags=(uint32_t)A(2);
    if (flags & ~(EVENT_CALLBACK|0x80000000u|0x08000000u|0x80000u)) return INVALID;
    WaveFormat format;memcpy(&format,P(5),sizeof(format));
    bool floating=format.tag==3,integer=format.tag==1;
    if (format.tag==0xfffe && format.extra>=22) {
        WaveExt extended;memcpy(&extended,P(5),sizeof(extended));
        floating=extended.subtype==FLOAT;integer=extended.subtype==PCM;
        if (extended.valid_bits!=format.bits || extended.mask!=(format.channels==1?4u:3u)) return UNSUPPORTED;
    }
    if ((!floating && !integer) || format.channels<1 || format.channels>2 || format.rate<8000 || format.rate>192000 ||
        (floating && format.bits!=32) || (integer && format.bits!=16) || format.alignment!=format.channels*format.bits/8 ||
        format.bytes_per_second!=format.rate*format.alignment) return UNSUPPORTED;
    const int64_t duration=(int64_t)A(3);
    if (duration<0 || duration>20000000 || A(4)) return INVALID;
    const uint32_t capacity=(uint32_t)std::max<int64_t>(2048,(duration*format.rate+9999999)/10000000);
    AudioComponentDescription description{kAudioUnitType_Output,kAudioUnitSubType_DefaultOutput,kAudioUnitManufacturer_Apple,0,0};
    AudioComponent component=AudioComponentFindNext(nullptr,&description);
    if (!component || AudioComponentInstanceNew(component,&client->unit)) return DEVICE_INVALIDATED;
    client->format=format;client->flags=flags;client->ring.resize((size_t)capacity*format.alignment);client->scratch.resize(client->ring.size());
    AudioStreamBasicDescription native{};native.mSampleRate=format.rate;native.mFormatID=kAudioFormatLinearPCM;
    native.mFormatFlags=(AudioFormatFlags)kAudioFormatFlagIsPacked|(AudioFormatFlags)kAudioFormatFlagsNativeEndian;
    if (floating) native.mFormatFlags|=kAudioFormatFlagIsFloat;else native.mFormatFlags|=kAudioFormatFlagIsSignedInteger;
    native.mBytesPerPacket=native.mBytesPerFrame=format.alignment;native.mFramesPerPacket=1;native.mChannelsPerFrame=format.channels;native.mBitsPerChannel=format.bits;
    AURenderCallbackStruct callback{AudioClient::render,client};
    OSStatus status=AudioUnitSetProperty(client->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&native,sizeof(native));
    if (!status) status=AudioUnitSetProperty(client->unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback));
    if (!status) status=AudioUnitInitialize(client->unit);
    if (status) { AudioComponentInstanceDispose(client->unit);client->unit=nullptr;fprintf(stderr,"audio: Core Audio initialization failed: %d\n",(int)status);return DEVICE_INVALIDATED; }
    client->notifications=dispatch_queue_create("local.sinking-star.audio-events",DISPATCH_QUEUE_SERIAL);
    client->notification=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0,0,client->notifications);
    dispatch_source_set_event_handler(client->notification,^{ if (client->running.load() && client->event) rt_signal_event(client->event); });
    dispatch_resume(client->notification);client->capacity=capacity;
    fprintf(stderr,"audio: initialized %u Hz, %u channels, %u-bit %s, %u frames, flags %#x\n",format.rate,format.channels,format.bits,floating?"float":"PCM",capacity,flags);
    return 0;
}
H(ClientBufferSize) { auto *s=owner<AudioClient>(c);if (!P(1))return POINTER;if (!s->capacity)return NOT_INITIALIZED;rt_put<uint32_t>(P(1),s->capacity);return 0; }
H(ClientLatency) { auto *s=owner<AudioClient>(c);if (!P(1))return POINTER;if (!s->capacity)return NOT_INITIALIZED;rt_put<int64_t>(P(1),(int64_t)s->capacity*10000000/s->format.rate);return 0; }
H(ClientPadding) { auto *s=owner<AudioClient>(c);if (!P(1))return POINTER;if (!s->capacity)return NOT_INITIALIZED;rt_put<uint32_t>(P(1),(uint32_t)s->padding());return 0; }
H(ClientMixFormat) { if (!P(1))return POINTER;const auto format=mix_format(owner<AudioClient>(c)->device);rt_put<uint64_t>(P(1),(uintptr_t)copy_memory(&format,sizeof(format)));return 0; }
H(ClientFormatSupported) {
    if (!P(2)) return POINTER;
    if (A(1)!=0) return UNSUPPORTED;
    if (P(3)) rt_put<uint64_t>(P(3),0);
    WaveFormat format;memcpy(&format,P(2),sizeof(format));
    const auto mix=mix_format(owner<AudioClient>(c)->device);
    if (format.tag==0xfffe && format.extra>=22 && !memcmp(P(2),&mix,sizeof(mix))) return 0;
    if (format.channels>=1 && format.channels<=2 && format.rate>=8000 && format.rate<=192000 &&
        ((format.tag==3 && format.bits==32)||(format.tag==1 && format.bits==16)) &&
        format.alignment==format.channels*format.bits/8 && format.bytes_per_second==format.rate*format.alignment) return 0;
    if (!P(3)) return POINTER;
    rt_put<uint64_t>(P(3),(uintptr_t)copy_memory(&mix,sizeof(mix)));return 1;
}
H(ClientPeriod) { if (!P(1) && !P(2))return POINTER;if (P(1))rt_put<int64_t>(P(1),100000);if (P(2))rt_put<int64_t>(P(2),30000);return 0; }
H(ClientStart) {
    auto *s=owner<AudioClient>(c);if (!s->capacity)return NOT_INITIALIZED;
    if ((s->flags&EVENT_CALLBACK) && !s->event)return EVENT_NOT_SET;
    if (s->running.exchange(true))return NOT_STOPPED;
    if (AudioOutputUnitStart(s->unit)) { s->running=false;return DEVICE_INVALIDATED; }
    if (s->event)rt_signal_event(s->event);return 0;
}
H(ClientStop) { auto *s=owner<AudioClient>(c);if (!s->capacity)return NOT_INITIALIZED;s->running=false;return AudioOutputUnitStop(s->unit)?DEVICE_INVALIDATED:0; }
H(ClientReset) { auto *s=owner<AudioClient>(c);if (!s->capacity)return NOT_INITIALIZED;if (s->running)return NOT_STOPPED;if (s->pending)return OUT_OF_ORDER;s->written=0;s->read=0;s->clock=0;return 0; }
H(ClientEvent) { auto *s=owner<AudioClient>(c);if (!s->capacity)return NOT_INITIALIZED;if (!(s->flags&EVENT_CALLBACK))return 0x88890011;if (s->event)return INVALID;auto event=rt_object(A(1));if (!event || event->kind!=Kind::Event)return INVALID;s->event=A(1);return 0; }
H(ClientService) {
    if (!P(2))return POINTER;rt_put<uint64_t>(P(2),0);if (!P(1))return POINTER;
    auto *s=owner<AudioClient>(c);if (!s->capacity)return NOT_INITIALIZED;
    RtGuid iid;memcpy(&iid,P(1),16);if (iid!=RENDER_IID && iid!=CLOCK_IID)return NO_INTERFACE;
    void *result=nullptr;const auto hr=s->query(iid,&result);rt_put<uint64_t>(P(2),(uintptr_t)result);return hr;
}
H(RenderBuffer) {
    auto *s=owner<AudioClient>(c);if (!P(2))return POINTER;rt_put<uint64_t>(P(2),0);if (!s->capacity)return NOT_INITIALIZED;
    if (s->pending)return OUT_OF_ORDER;const uint64_t frames=A(1);
    if (frames>s->capacity-s->padding())return BUFFER_TOO_LARGE;if (!frames)return 0;
    s->pending=(uint32_t)frames;rt_put<uint64_t>(P(2),(uintptr_t)s->scratch.data());return 0;
}
H(RenderRelease) {
    auto *s=owner<AudioClient>(c);if (!s->capacity)return NOT_INITIALIZED;
    if (!s->pending)return A(1)?OUT_OF_ORDER:0;
    if (A(1)>s->pending)return INVALID_SIZE;if (A(2)&~2u)return INVALID;
    const uint32_t frames=(uint32_t)A(1);if (A(2)&2)memset(s->scratch.data(),0,(size_t)frames*s->format.alignment);
    const uint64_t head=s->written.load(std::memory_order_relaxed);const uint32_t offset=(uint32_t)(head%s->capacity),first=std::min(frames,s->capacity-offset);
    memcpy(s->ring.data()+(size_t)offset*s->format.alignment,s->scratch.data(),(size_t)first*s->format.alignment);
    memcpy(s->ring.data(),s->scratch.data()+(size_t)first*s->format.alignment,(size_t)(frames-first)*s->format.alignment);
    s->written.store(head+frames,std::memory_order_release);s->submitted.fetch_add(frames,std::memory_order_relaxed);s->pending=0;return 0;
}
H(ClockFrequency) { if (!P(1))return POINTER;auto *s=owner<AudioClient>(c);if (!s->capacity)return NOT_INITIALIZED;rt_put<uint64_t>(P(1),s->format.rate);return 0; }
H(ClockPosition) { if (!P(1))return POINTER;auto *s=owner<AudioClient>(c);if (!s->capacity)return NOT_INITIALIZED;rt_put<uint64_t>(P(1),s->clock.load());if (P(2))rt_put<uint64_t>(P(2),std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count()/100);return 0; }
H(ClockCharacteristics) { if (!P(1))return POINTER;rt_put<uint32_t>(P(1),1);return 0; }
AudioClient *create_client(const DeviceInfo &device) {
    static const auto client=rt_com_vtable({{"IAudioClient.Initialize",ClientInitialize},{"IAudioClient.GetBufferSize",ClientBufferSize},{"IAudioClient.GetStreamLatency",ClientLatency},{"IAudioClient.GetCurrentPadding",ClientPadding},{"IAudioClient.IsFormatSupported",ClientFormatSupported},{"IAudioClient.GetMixFormat",ClientMixFormat},{"IAudioClient.GetDevicePeriod",ClientPeriod},{"IAudioClient.Start",ClientStart},{"IAudioClient.Stop",ClientStop},{"IAudioClient.Reset",ClientReset},{"IAudioClient.SetEventHandle",ClientEvent},{"IAudioClient.GetService",ClientService}});
    static const auto render=rt_com_vtable({{"IAudioRenderClient.GetBuffer",RenderBuffer},{"IAudioRenderClient.ReleaseBuffer",RenderRelease}});
    static const auto clock=rt_com_vtable({{"IAudioClock.GetFrequency",ClockFrequency},{"IAudioClock.GetPosition",ClockPosition},{"IAudioClock.GetCharacteristics",ClockCharacteristics}});
    return new AudioClient(device,{{CLIENT_IID,client.data()},{RENDER_IID,render.data()},{CLOCK_IID,clock.data()}});
}

class DeviceObject final : public RtComObject {
public:
    DeviceObject(const DeviceInfo &device,std::initializer_list<RtComInterfaceSpec> specs):RtComObject(specs),device(device) {}
    DeviceInfo device;
};
H(PropertyCount) { if (!P(1))return POINTER;rt_put<uint32_t>(P(1),PROPERTY_KEYS.size());return 0; }
H(PropertyAt) { if (!P(2))return POINTER;if (A(1)>=PROPERTY_KEYS.size())return INVALID;rt_put(P(2),PROPERTY_KEYS[A(1)]);return 0; }
H(PropertyValue) {
    if (!P(1) || !P(2))return POINTER;memset(P(2),0,24);
    PropertyKey key;memcpy(&key,P(1),sizeof(key));const auto &device=owner<DeviceObject>(c)->device;
    auto *out=(uint8_t *)(uintptr_t)A(2);
    if (key==NAME) { rt_put<uint16_t>(out,31);rt_put<uint64_t>(out+8,(uintptr_t)copy_string(device.name));return 0; }
    if (key==FORMAT) { const auto format=mix_format(device);rt_put<uint16_t>(out,65);rt_put<uint32_t>(out+8,sizeof(format));rt_put<uint64_t>(out+16,(uintptr_t)copy_memory(&format,sizeof(format)));return 0; }
    if (key==SPEAKERS) { rt_put<uint16_t>(out,19);rt_put<uint32_t>(out+8,3);return 0; }
    return NOT_FOUND;
}
H(PropertySet) { return ACCESS; }
H(PropertyCommit) { return ACCESS; }
H(DeviceProperties) {
    if (!P(2))return POINTER;rt_put<uint64_t>(P(2),0);if (A(1))return ACCESS;
    static const auto table=rt_com_vtable({{"IPropertyStore.GetCount",PropertyCount},{"IPropertyStore.GetAt",PropertyAt},{"IPropertyStore.GetValue",PropertyValue},{"IPropertyStore.SetValue",PropertySet},{"IPropertyStore.Commit",PropertyCommit}});
    return give(new DeviceObject(owner<DeviceObject>(c)->device,{{PROPERTY_IID,table.data()}}),PROPERTY_IID,P(2));
}
H(DeviceId) { if (!P(1))return POINTER;rt_put<uint64_t>(P(1),(uintptr_t)copy_string(owner<DeviceObject>(c)->device.id));return 0; }
H(DeviceState) { if (!P(1))return POINTER;rt_put<uint32_t>(P(1),1);return 0; }
H(EndpointFlow) { if (!P(1))return POINTER;rt_put<uint32_t>(P(1),0);return 0; }
H(DeviceActivate) {
    if (!P(4))return POINTER;rt_put<uint64_t>(P(4),0);if (!P(1))return POINTER;
    RtGuid iid;memcpy(&iid,P(1),16);
    if (iid!=CLIENT_IID) { fprintf(stderr,"audio: unsupported activation IID %08x-%04x-%04x\n",iid.data1,iid.data2,iid.data3);return NO_INTERFACE; }
    if (!(A(2)&1) || P(3))return INVALID;
    return give(create_client(owner<DeviceObject>(c)->device),CLIENT_IID,P(4));
}
uint32_t give_device(const DeviceInfo &device,void *out) {
    static const auto table=rt_com_vtable({{"IMMDevice.Activate",DeviceActivate},{"IMMDevice.OpenPropertyStore",DeviceProperties},{"IMMDevice.GetId",DeviceId},{"IMMDevice.GetState",DeviceState}});
    static const auto endpoint=rt_com_vtable({{"IMMEndpoint.GetDataFlow",EndpointFlow}});
    return give(new DeviceObject(device,{{DEVICE_IID,table.data()},{ENDPOINT_IID,endpoint.data()}}),DEVICE_IID,out);
}
class Collection final : public RtComObject {
public:
    Collection(DeviceInfo device,bool present,const uint64_t *table):RtComObject({{COLLECTION_IID,table}}),device(std::move(device)),present(present) {}
    DeviceInfo device;bool present;
};
H(CollectionCount) { if (!P(1))return POINTER;rt_put<uint32_t>(P(1),owner<Collection>(c)->present?1:0);return 0; }
H(CollectionItem) { if (!P(2))return POINTER;rt_put<uint64_t>(P(2),0);auto *s=owner<Collection>(c);if (A(1) || !s->present)return INVALID;return give_device(s->device,P(2)); }
class Enumerator final : public RtComObject {
public:
    explicit Enumerator(const uint64_t *table):RtComObject({{ENUM_IID,table}}) {}
};
H(EnumDevices) {
    if (!P(3))return POINTER;rt_put<uint64_t>(P(3),0);if (A(1)>2 || (A(2)&~15u))return INVALID;
    const auto device=default_device();
    static const auto table=rt_com_vtable({{"IMMDeviceCollection.GetCount",CollectionCount},{"IMMDeviceCollection.Item",CollectionItem}});
    return give(new Collection(device,device.native && A(1)!=1 && (A(2)&1),table.data()),COLLECTION_IID,P(3));
}
H(DefaultEndpoint) { if (!P(3))return POINTER;rt_put<uint64_t>(P(3),0);if (A(1)>1 || A(2)>2)return INVALID;if (A(1))return NOT_FOUND;const auto device=default_device();if (!device.native)return NOT_FOUND;return give_device(device,P(3)); }
H(FindDevice) { if (!P(2))return POINTER;rt_put<uint64_t>(P(2),0);if (!P(1))return POINTER;const auto device=default_device();if (!device.native || device.id!=(const char16_t *)P(1))return NOT_FOUND;return give_device(device,P(2)); }
// shortcut: endpoint changes are not delivered, add notifications with R5.04 device switching.
H(RegisterNotification) { return NOT_IMPL; }
H(UnregisterNotification) { return NOT_IMPL; }
RtComObject *create_enumerator() {
    static const auto table=rt_com_vtable({{"IMMDeviceEnumerator.EnumAudioEndpoints",EnumDevices},{"IMMDeviceEnumerator.GetDefaultAudioEndpoint",DefaultEndpoint},{"IMMDeviceEnumerator.GetDevice",FindDevice},{"IMMDeviceEnumerator.RegisterEndpointNotificationCallback",RegisterNotification},{"IMMDeviceEnumerator.UnregisterEndpointNotificationCallback",UnregisterNotification}});
    return new Enumerator(table.data());
}
}
void rt_audio_init() {
    static std::once_flag once;
    std::call_once(once,[]{if (!rt_com_register_class(ENUM_CLASS,create_enumerator))rt_fatal("cannot register Core Audio endpoint enumerator");});
}

#include "runtime.h"
#import <GameController/GameController.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <mutex>
#include <vector>

namespace {
struct Gamepad {
    uint16_t buttons;
    uint8_t left_trigger, right_trigger;
    int16_t lx, ly, rx, ry;
};
struct State { uint32_t packet; Gamepad gamepad; };
static_assert(sizeof(Gamepad) == 12 && sizeof(State) == 16);
struct Slot { GCController *__strong controller = nil; State state = {}; };
struct Device { GCController *__strong controller; uint64_t identity; };
struct Change { uint64_t identity; bool connected; };
std::mutex mutex;
std::array<Slot, 4> slots;
std::vector<Device> devices;
std::vector<Change> changes;
uint64_t next_identity = 1;

void connect(GCController *controller, bool notify) {
    if (!controller.extendedGamepad) return;
    std::lock_guard lock(mutex);
    if (std::any_of(devices.begin(), devices.end(), [=](const Device &d) { return d.controller == controller; })) return;
    const uint64_t identity = next_identity++;
    devices.push_back({controller, identity});
    for (auto &slot : slots) if (!slot.controller) {
        slot.controller = controller;
        ++slot.state.packet;
        slot.state.gamepad = {};
        break;
    }
    if (notify) changes.push_back({identity, true});
}
void disconnect(GCController *controller) {
    std::lock_guard lock(mutex);
    auto device = std::find_if(devices.begin(), devices.end(), [=](const Device &d) { return d.controller == controller; });
    if (device == devices.end()) return;
    changes.push_back({device->identity, false});
    devices.erase(device);
    for (auto &slot : slots) if (slot.controller == controller) {
        slot.controller = nil;
        slot.state.gamepad = {};
        for (const auto &candidate : devices) {
            if (std::none_of(slots.begin(), slots.end(), [&](const Slot &s) { return s.controller == candidate.controller; })) {
                slot.controller = candidate.controller;
                ++slot.state.packet;
                break;
            }
        }
    }
}
int16_t axis(float value) {
    value = std::clamp(value, -1.f, 1.f);
    return (int16_t)lroundf(value * (value < 0 ? 32768.f : 32767.f));
}
Gamepad sample(GCExtendedGamepad *pad) {
    const std::pair<GCControllerButtonInput *, uint16_t> buttons[] = {
        {pad.dpad.up, 1}, {pad.dpad.down, 2}, {pad.dpad.left, 4}, {pad.dpad.right, 8},
        {pad.buttonMenu, 0x10}, {pad.buttonOptions, 0x20},
        {pad.leftThumbstickButton, 0x40}, {pad.rightThumbstickButton, 0x80},
        {pad.leftShoulder, 0x100}, {pad.rightShoulder, 0x200},
        {pad.buttonA, 0x1000}, {pad.buttonB, 0x2000}, {pad.buttonX, 0x4000}, {pad.buttonY, 0x8000},
    };
    Gamepad result = {};
    for (const auto &[button, mask] : buttons) if (button.pressed) result.buttons |= mask;
    result.left_trigger = (uint8_t)lroundf(std::clamp(pad.leftTrigger.value, 0.f, 1.f) * 255.f);
    result.right_trigger = (uint8_t)lroundf(std::clamp(pad.rightTrigger.value, 0.f, 1.f) * 255.f);
    result.lx = axis(pad.leftThumbstick.xAxis.value); result.ly = axis(pad.leftThumbstick.yAxis.value);
    result.rx = axis(pad.rightThumbstick.xAxis.value); result.ry = axis(pad.rightThumbstick.yAxis.value);
    return result;
}
H(XInputGetState) {
    const uint32_t index = (uint32_t)A(0);
    if (index >= slots.size() || !P(1)) return 160; // XInput returns errors directly, without SetLastError.
    rt_gamepad_init();
    @autoreleasepool {
        std::lock_guard lock(mutex);
        auto &slot = slots[index];
        if (!slot.controller) return 1167;
        const Gamepad current = sample([slot.controller capture].extendedGamepad);
        if (memcmp(&current, &slot.state.gamepad, sizeof current)) {
            slot.state.gamepad = current;
            ++slot.state.packet;
        }
        rt_put(P(1), slot.state);
    }
    return 0;
}
}

void rt_gamepad_init() {
    static std::once_flag initialized;
    std::call_once(initialized, [] {
        @autoreleasepool {
            // XInput polling is independent of keyboard focus; the guest decides when to act on it.
            GCController.shouldMonitorBackgroundEvents = YES;
            static id connected, disconnected;
            connected = [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *note) { connect(note.object, true); }];
            disconnected = [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil usingBlock:^(NSNotification *note) { disconnect(note.object); }];
            (void)connected; (void)disconnected;
            for (GCController *controller in GCController.controllers) connect(controller, false);
        }
    });
}
void rt_gamepad_pump() {
    std::vector<Change> pending;
    { std::lock_guard lock(mutex); pending.swap(changes); }
    for (const auto &change : pending) rt_window_device_change(change.identity, change.connected);
}

const RtEntry rt_gamepad_entries[] = {{"XInputGetState", XInputGetState}, {nullptr, nullptr}};

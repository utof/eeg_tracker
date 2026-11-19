// Golden E9 frames from the board firmware's own framing code (eeg_ads1299_lab, MIT licence):
// firmware/esp32_ads1299_bench/portable_core.h. Build and run from this repo's root, with the
// sibling repo checked out next to it (read only; nothing is copied from it):
//   g++ -std=c++17 -I ../eeg_ads1299_lab/firmware/esp32_ads1299_bench tests/fake_diy/golden/make_golden.cpp -o /tmp/make_golden
//   /tmp/make_golden > tests/fake_diy/golden/e9_vectors.json
// Made 2026-11-19 from eeg_ads1299_lab main 7aa87b2 (portable_core.h blob 7ce32d1); vector 1 is byte for byte
// the output of that repo's tests/native_core_test.cpp.
// Each line of the output names its inputs, the packet bytes eeglab::packet() made (hex) and the
// channel values eeglab::decode24() reads back from the native frame.
#include "portable_core.h"
#include <cstdio>
#include <cstring>

namespace {
void word(uint8_t* p, uint32_t v) { p[0] = uint8_t(v >> 16); p[1] = uint8_t(v >> 8); p[2] = uint8_t(v); }

bool first = true;
void emit(const char* name, uint32_t status, const int32_t* codes, uint8_t channels, uint8_t gain,
          uint16_t fs, uint8_t flags, uint32_t seq, uint32_t tick, uint32_t overruns) {
    uint8_t frame[27] = {0};
    word(frame, status);
    for (int c = 0; c < channels; ++c) word(frame + 3 + 3 * c, uint32_t(codes[c]) & 0xffffff);
    uint8_t out[eeglab::MAX_PACKET_SIZE] = {0};
    const std::size_t n = eeglab::packet(out, sizeof(out), frame, channels, gain, fs, flags, seq, tick, overruns);
    std::printf("%s{\"name\": \"%s\", \"size\": %zu, \"hex\": \"", first ? "[\n" : ",\n", name, n);
    first = false;
    for (std::size_t i = 0; i < n; ++i) std::printf("%02x", out[i]);
    std::printf("\", \"channels\": %u, \"gain\": %u, \"fs\": %u, \"flags\": %u, \"seq\": %u, \"tick\": %u, "
                "\"overruns\": %u, \"status\": %u, \"codes\": [", channels, gain, fs, flags, seq, tick, overruns, status);
    for (int c = 0; c < channels; ++c) std::printf("%s%d", c ? ", " : "", eeglab::decode24(frame + 3 + 3 * c));
    std::printf("]}");
}
}  // namespace

int main() {
    // 1. The firmware repo's own vector (tests/native_core_test.cpp): extremes of the 24-bit range.
    const int32_t extremes[] = {-8388608, -1, 0, 8388607};
    emit("native_core_test", 0xc00000, extremes, 4, 24, 250, 4, 0xffffffffu, 1234567, 9);
    // 2. What the breadboard build sends after T: internal test signal (flag 1), 250 SPS, gain 24.
    //    83886 counts = VREF/2400 at gain 24 (the +-1.875 mV square wave), for any VREF.
    const int32_t square[] = {83886, 83886, -83886, 0};
    emit("breadboard_test_signal", 0xc00000, square, 4, 24, 250, 1, 1, 4000, 0);
    // 3. After N on the 8-channel chip with device-side overruns (flag 2 | 8), lead-off and GPIO bits set,
    //    the device clock just before its uint32 wrap.
    const int32_t mixed[] = {1, -2, 300, -4000, 50000, -600000, 7000000, -8000000};
    emit("eight_channels_short_overrun", 0xcff0f5, mixed, 8, 24, 250, 2 | 8, 1000, 0xfffff000u, 3);
    // 4. A six-channel chip, gain 1, sequence at 2^31 (the format allows it; the bench firmware refuses 6 ch).
    const int32_t six[] = {-8388608, 8388607, 1, -1, 4660, -4660};
    emit("six_channels_gain_1", 0xc12345, six, 6, 1, 250, 1, 0x80000000u, 0, 0);
    std::printf("\n]\n");
    // Refusals of the same function: 5 channels, a status word without the 0xC prefix, too small a buffer.
    uint8_t frame[27] = {0xc0}, bad[27] = {0xb0}, out[49];
    if (eeglab::packet(out, sizeof(out), frame, 5, 24, 250, 1, 0, 0, 0) != 0) return 1;
    if (eeglab::packet(out, sizeof(out), bad, 4, 24, 250, 1, 0, 0, 0) != 0) return 1;
    if (eeglab::packet(out, 36, frame, 4, 24, 250, 1, 0, 0, 0) != 0) return 1;
    const uint8_t check[] = "123456789";
    return eeglab::crc16(check, 9) == 0x29b1 ? 0 : 1;
}

#ifndef PIPEWIREAO_RTC_BINDGEN_COMPAT_H
#define PIPEWIREAO_RTC_BINDGEN_COMPAT_H

#include <stdbool.h>
#include <stdint.h>

struct spa_meta_acquisition;

/*
 * PipeWireAO-rs 1455233 still declares a retired wire codec. Keep its generated
 * crate compilable until 4691194 is published. The RTC runner never calls it.
 */
#define SPA_META_ACQUISITION_WIRE_SIZE 96u

bool spa_meta_acquisition_serialize(
    const struct spa_meta_acquisition *acquisition,
    uint8_t *wire,
    uint32_t wire_size);

bool spa_meta_acquisition_deserialize(
    struct spa_meta_acquisition *acquisition,
    const uint8_t *wire,
    uint32_t wire_size);

#endif

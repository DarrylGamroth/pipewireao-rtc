#include <pipewire/impl.h>

/* Link-only compatibility for retired functions referenced by the currently
 * published Rust crate. No runner code calls these functions. */
bool spa_meta_acquisition_serialize(
        const struct spa_meta_acquisition *acquisition,
        uint8_t *wire, uint32_t wire_size)
{
    (void)acquisition;
    (void)wire;
    (void)wire_size;
    return false;
}

bool spa_meta_acquisition_deserialize(
        struct spa_meta_acquisition *acquisition,
        const uint8_t *wire, uint32_t wire_size)
{
    (void)acquisition;
    (void)wire;
    (void)wire_size;
    return false;
}

void *pipewireao_rtc_context_load_module(void *context,
                                         const char *name,
                                         const char *args)
{
    return pw_context_load_module(context, name, args, NULL);
}

void pipewireao_rtc_module_destroy(void *module)
{
    pw_impl_module_destroy(module);
}

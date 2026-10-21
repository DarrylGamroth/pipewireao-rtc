#include REVIEW_SOURCE
#include <spa/pod/builder.h>
int main(int argc, char **argv) {
  wp_init(WP_INIT_ALL);
  char buffer[64];
  struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  struct spa_pod_frame frame;
  spa_pod_builder_push_struct(&builder, &frame);
  spa_pod_builder_int(&builder, 42);
  const struct spa_pod *raw = spa_pod_builder_pop(&builder, &frame);
  g_autoptr(WpSpaPod) pod = copy_value(raw);
  g_autoptr(WpIterator) it = wp_ao_lua_fields(NULL, pod);
  g_auto(GValue) item = G_VALUE_INIT;
  g_assert_nonnull(it);
  g_assert_true(wp_iterator_next(it, &item));
  gint actual = 0;
  g_assert_true(wp_spa_pod_get_int(g_value_get_boxed(&item), &actual));
  g_assert_cmpint(actual, ==, 42);
  return 0;
}

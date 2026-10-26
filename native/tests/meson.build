wp_source = get_option('wp_source_dir')
if wp_source == ''
  error('Tests require -Dwp_source_dir=/path/to/wireplumber source checkout')
endif
fs = import('fs')
if not fs.is_file(wp_source / 'tests/script-tester.c')
  error('wp_source_dir does not contain the upstream script-tester.c harness')
endif

test_env = environment()
test_env.set('HOME', '/invalid')
test_env.prepend('LD_LIBRARY_PATH', pw.get_variable(pkgconfig: 'libdir'))
test_env.prepend('LD_LIBRARY_PATH', wp.get_variable(pkgconfig: 'libdir'))
test_env.set('XDG_RUNTIME_DIR', '/invalid')
test_env.set('PIPEWIREAO_RUNTIME_DIR', '/tmp')
test_env.set('XDG_CONFIG_HOME', meson.current_build_dir() / '.config')
test_env.set('XDG_STATE_HOME', meson.current_build_dir() / '.state')
test_env.set('G_TEST_SRCDIR', wp_source / 'tests/wplua')
test_env.set('G_TEST_BUILDDIR', meson.current_build_dir())
test_env.set('WIREPLUMBER_MODULE_DIR', meson.project_build_root() / 'modules' + ':' + wp_module_dir)
test_env.set('WIREPLUMBER_DATA_DIR', meson.current_source_dir() + ':' + meson.project_source_root() + ':' + wp_data_dir)
test_env.set('PIPEWIREAO_SPA_PLUGIN_DIR', spa.get_variable(pkgconfig: 'plugindir'))
test_env.set('PIPEWIREAO_MODULE_DIR', pw.get_variable(pkgconfig: 'moduledir'))
test_env.set('PIPEWIREAO_CONFIG_DIR', pw.get_variable(pkgconfig: 'prefix') / 'share/pipewire-ao')

# Include the upstream runner in place and add RTC's own native component.
test_config = configuration_data()
test_config.set_quoted('RTC_WP_SCRIPT_TESTER_SOURCE', wp_source / 'tests/script-tester.c')
configure_file(output: 'rtc-test-build.h', configuration: test_config)
script_tester = executable('script-tester', 'script-tester.c',
  include_directories: include_directories(wp_source / 'tests/wplua'),
  dependencies: [wp, pw])
foreach name : ['ao-lua', 'ao-connections', 'ao-owner', 'ao-acquisition', 'ao-correction', 'ao-session-journal', 'ao-session-hooks', 'ao-session-correction']
  test(name, script_tester, args: ['lua-api-tests', name + '.lua'], env: test_env, timeout: 30)
endforeach
journal = executable('test-ao-journal', 'ao-journal.c', dependencies: [wp, pw, sqlite])
test('ao-journal', journal, env: test_env, timeout: 30)
host_test = executable('test-rtc-host', 'host.c',
  include_directories: include_directories(wp_source / 'tests/common'),
  dependencies: [wp, pw])
test_env.set('RTC_TEST_BINARY', rtc.full_path())
test_env.set('RTC_TEST_SOURCE', meson.current_source_dir())
test_env.set('RTC_TEST_SCRIPT', meson.current_source_dir() / 'scripts/host-ready.lua')
test('rtc-host', host_test, env: test_env, depends: [rtc] + rtc_modules, timeout: 30)

links = executable('test-ao-links',
  ['ao-links.c', '../modules/ao-link.c', '../modules/module-ao-control-endpoint.c'],
  include_directories: include_directories(wp_source / 'tests/common'),
  dependencies: [wp, pw])
test('ao-links', links, env: test_env, timeout: 30)

lua_bindings = executable('test-ao-lua', 'ao-lua.c',
  include_directories: include_directories(wp_source / 'tests/common'),
  dependencies: [wp, pw])
test('ao-lua-native', lua_bindings, env: test_env, timeout: 30)

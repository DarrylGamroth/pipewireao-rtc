project('pipewireao-rtc', 'c', version: '0.1.0',
  license: 'MIT', meson_version: '>= 0.61',
  default_options: ['c_std=gnu11', 'warning_level=2'])

wp = dependency('wireplumber-0.5', version: '>= 0.5.18')
pw = dependency('libpipewire-ao-0.3')
spa = dependency('libspa-ao-0.2')
sqlite = dependency('sqlite3', version: '>= 3.24')
gio_unix = dependency('gio-unix-2.0')
app_module_dir = get_option('prefix') / get_option('libdir') / 'pipewireao-rtc/modules'
app_data_dir = get_option('prefix') / get_option('datadir') / 'pipewireao-rtc'
wp_prefix = wp.get_variable(pkgconfig: 'prefix')
wp_module_dir = wp.get_variable(pkgconfig: 'libdir') / 'wireplumber-0.5'
wp_data_dir = wp_prefix / 'share/wireplumber'

config = configuration_data()
config.set_quoted('RTC_MODULE_DIR', app_module_dir)
config.set_quoted('RTC_DATA_DIR', app_data_dir)
config.set_quoted('WP_MODULE_DIR', wp_module_dir)
config.set_quoted('WP_DATA_DIR', wp_data_dir)
configure_file(output: 'rtc-build.h', configuration: config)
rtc = executable('pipewireao-rtc', 'main.c',
  dependencies: [wp, pw, gio_unix], install: true)
rtc_modules = []
subdir('modules')
install_subdir('scripts', install_dir: app_data_dir)
install_data('LICENSE', install_dir: get_option('datadir') / 'licenses/pipewireao-rtc')

if get_option('tests')
  subdir('tests')
endif

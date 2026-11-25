project('pipewireao-rtc', 'c', version: '0.1.0',
  license: 'MIT', meson_version: '>= 0.61',
  default_options: ['c_std=gnu11', 'warning_level=2'])

# The selected session runtime is Julia/PipeWireAO.jl. Only the independent cold
# management companion remains a native executable in this build.
gio_unix = dependency('gio-unix-2.0')
json = dependency('json-c', version: '>= 0.18')
management = executable('pipewireao-management', 'management.c',
  dependencies: [json, gio_unix], install: true)
install_data('LICENSE', install_dir: get_option('datadir') / 'licenses/pipewireao-rtc')

if get_option('tests')
  subdir('tests')
endif

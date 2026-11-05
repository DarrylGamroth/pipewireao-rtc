foreach name : ['ao-control-endpoint', 'ao-journal', 'ao-lua']
  sources = ['module-' + name + '.c']
  if name == 'ao-control-endpoint'
    sources += ['ao-link.c']
  endif
  rtc_modules += [shared_module('wireplumber-module-' + name, sources,
    dependencies: [wp, pw, sqlite], install: true, install_dir: app_module_dir)]
endforeach

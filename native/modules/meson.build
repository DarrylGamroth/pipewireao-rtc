foreach name : ['ao-control-endpoint', 'ao-journal']
  rtc_modules += [shared_module('wireplumber-module-' + name, 'module-' + name + '.c',
    dependencies: [wp, pw, sqlite], install: true, install_dir: app_module_dir)]
endforeach

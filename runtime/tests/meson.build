# Independent management tests; retired WirePlumber policy is not selected.
management_activation = executable('management-activate', 'management-activate.c')
management_json = executable('test-management-json', 'management-json.c',
  dependencies: [json, gio_unix])
test('management-json', management_json)

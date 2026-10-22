project('rs6-spdif', 'c',
  version: '1.0',
  license: 'MIT',
  meson_version: '>= 0.61',
  default_options: ['warning_level=2', 'c_std=gnu11', 'buildtype=debugoptimized'])

alsa = dependency('alsa', version: '>= 1.1.6')
threads = dependency('threads')

# where alsa-lib looks for libasound_module_*.so: <alsa libdir>/alsa-lib
# (/usr/lib/alsa-lib on Alpine and Arch, /usr/lib/<triplet>/alsa-lib on Debian)
plugindir = get_option('alsa_plugin_dir')
if plugindir == ''
  plugindir = alsa.get_variable(pkgconfig: 'libdir') / 'alsa-lib'
endif
alsa_confd = get_option('datadir') / 'alsa' / 'alsa.conf.d'

core = static_library('iec958', 'iec958.c', pic: true)

# alsa/global.h: PIC selects the dynamic-module form of SND_*_PLUGIN_SYMBOL
plugin_args = ['-DPIC']

pcm_plugin = shared_module('asound_module_pcm_rs6_spdif',
  'pcm_rs6_spdif.c', 'rs6-target.c',
  name_prefix: 'lib',
  c_args: plugin_args,
  link_with: core,
  dependencies: [alsa, threads],
  install: true,
  install_dir: plugindir)

ctl_plugin = shared_module('asound_module_ctl_rs6_jack',
  'ctl_rs6_jack.c', 'rs6-target.c',
  name_prefix: 'lib',
  c_args: plugin_args,
  dependencies: alsa,
  install: true,
  install_dir: plugindir)

install_data('50-rs6-spdif.conf', install_dir: alsa_confd)
if get_option('etc_conf_link')
  # alsa-lib reads /etc/alsa/conf.d; distributions link their plugin configs there
  install_symlink('50-rs6-spdif.conf',
    install_dir: get_option('sysconfdir') / 'alsa' / 'conf.d',
    pointing_to: get_option('prefix') / alsa_confd / '50-rs6-spdif.conf')
endif

# ---- tests ----
test_encoder = executable('test-encoder', 'test-encoder.c', link_with: core)
test('encoder', test_encoder)

encode_cli = executable('rs6-spdif-encode', 'rs6-spdif-encode.c', link_with: core)
python = find_program('python3', required: false)
if python.found()
  test('reference', python,
    args: [files('test-ref.py'), encode_cli],
    timeout: 300)
endif

test_conf = configure_file(
  input: 'test-alsa.conf.in',
  output: 'test-alsa.conf',
  configuration: {
    'PCM_LIB': pcm_plugin.full_path(),
    'CTL_LIB': ctl_plugin.full_path(),
    'CAPTURE': meson.current_build_dir() / 'test-capture.raw',
  })
alsa_conf = get_option('alsa_conf')
if alsa_conf == ''
  alsa_conf = alsa.get_variable(pkgconfig: 'prefix') / 'share' / 'alsa' / 'alsa.conf'
endif
test_env = {
  'ALSA_CONFIG_PATH': alsa_conf + ':' + meson.current_build_dir() / 'test-alsa.conf',
  'RS6_TEST_CAPTURE': meson.current_build_dir() / 'test-capture.raw',
}
test_plugin = executable('test-plugin', 'test-plugin.c', link_with: core, dependencies: alsa)
test('plugin', test_plugin,
  depends: pcm_plugin,
  env: test_env,
  is_parallel: false,
  timeout: 300)

# needs a sound card for a stand-in control: RS6_TEST_CTL_CARD=<index> meson test target
test_target = executable('test-target', 'test-target.c', dependencies: alsa)
test('target', test_target,
  depends: [pcm_plugin, ctl_plugin],
  env: test_env,
  is_parallel: false,
  timeout: 60)

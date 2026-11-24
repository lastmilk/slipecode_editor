vm_target = RUBY_PLATFORM.include?('arm64') ? 'macos_arm64' : 'macos_x64'
require 'rbconfig'

package_root = File.expand_path('..', __dir__)
luajit_root = File.join(package_root, 'src', 'luajit')
vm_target = RbConfig::CONFIG['host_cpu'].include?('arm64') ? 'macos_arm64' : 'macos_x64'
generated_root = File.join(luajit_root, 'generated', vm_target)

Pod::Spec.new do |s|
  s.name = 'slipe_lua'
  s.version = '0.1.0'
  s.summary = 'Restricted per-plugin LuaJIT runtime for SLIPE desktop.'
  s.homepage = 'https://slipe.dev'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = { 'SLIPE' => 'dev@slipe.dev' }
  s.source = { :path => '.' }
  s.platform = :osx, '11.0'
  s.dependency 'FlutterMacOS'

  s.source_files = [
    '../src/bridge/*.{c,h}',
    '../src/luajit/src/ljamalg.c',
    '../src/luajit/src/**/*.h',
    "../src/luajit/generated/#{vm_target}/*.{h,S}"
  ]
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LUAJIT_DISABLE_FFI=1 LUAJIT_ENABLE_OSX_HRT=1 LUAJIT_UNWIND_EXTERNAL=1',
    'HEADER_SEARCH_PATHS' => "$(inherited) \"#{File.join(package_root, 'src', 'bridge')}\" \"#{File.join(luajit_root, 'src')}\" \"#{File.join(luajit_root, 'dynasm')}\" \"#{generated_root}\"",
    'OTHER_CFLAGS' => '$(inherited) -fno-strict-aliasing -fno-omit-frame-pointer'
  }
  s.libraries = 'm'
end

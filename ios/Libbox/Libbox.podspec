# sing-box as an iOS framework. tool/build_libbox.sh produces Libbox.xcframework here.
Pod::Spec.new do |s|
  s.name = 'Libbox'
  s.version = '1.14.4'
  s.summary = 'sing-box bindings for the packet tunnel'
  s.homepage = 'https://github.com/SagerNet/sing-box'
  s.license = { :type => 'GPL-3.0-or-later' }
  s.author = 'SagerNet'
  s.source = { :path => '.' }
  s.platform = :ios, '15.0'
  s.vendored_frameworks = 'Libbox.xcframework'
  s.libraries = 'resolv'
  s.frameworks = 'Foundation', 'Network', 'NetworkExtension', 'Security', 'SystemConfiguration'
end

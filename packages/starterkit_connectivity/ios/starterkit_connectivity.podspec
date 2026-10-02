Pod::Spec.new do |s|
  s.name             = 'starterkit_connectivity'
  s.version          = '1.0.0'
  s.summary          = 'Explicit native interface connectivity status stream.'
  s.description      = 'A low-level Flutter plugin for explicitly subscribed network interface status.'
  s.homepage         = 'https://example.invalid/starterkit_connectivity'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Starter Kit' => 'maintainers@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end

Pod::Spec.new do |s|
  s.name             = 'starterkit_platform'
  s.version          = '1.0.0'
  s.summary          = 'Disconnected native platform capabilities.'
  s.description      = 'Explicit Camera and Gallery adapters with bounded private media handling.'
  s.homepage         = 'https://example.invalid/starterkit_platform'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Starter Kit' => 'maintainers@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'UIKit', 'AVFoundation', 'PhotosUI', 'ImageIO'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end

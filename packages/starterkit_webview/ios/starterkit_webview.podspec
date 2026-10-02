Pod::Spec.new do |s|
  s.name             = 'starterkit_webview'
  s.version          = '1.0.0'
  s.summary          = 'Explicit native WebView capability.'
  s.description      = 'A disconnected Flutter platform view with strict trusted-origin and bridge policy.'
  s.homepage         = 'https://example.invalid/starterkit_webview'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Starter Kit' => 'maintainers@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'WebKit', 'UIKit'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end

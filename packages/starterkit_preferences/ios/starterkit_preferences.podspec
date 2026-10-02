Pod::Spec.new do |s|
  s.name             = 'starterkit_preferences'
  s.version          = '1.0.0'
  s.summary          = 'Optional bounded native string preferences.'
  s.description      = 'A low-level Flutter plugin for explicitly operated, non-sensitive string preferences.'
  s.homepage         = 'https://example.invalid/starterkit_preferences'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Starter Kit' => 'maintainers@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end

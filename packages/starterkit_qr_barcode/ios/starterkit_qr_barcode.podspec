Pod::Spec.new do |s|
  s.name             = 'starterkit_qr_barcode'
  s.version          = '1.0.0'
  s.summary          = 'Still-image QR and barcode decoding capability.'
  s.description      = 'Opt-in still-image decoding using system Vision and ImageIO.'
  s.homepage         = 'https://example.invalid/starterkit_qr_barcode'
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = { 'Starter Kit' => 'maintainers@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'Vision', 'ImageIO'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end

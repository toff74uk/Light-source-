platform :ios, '15.0'
inhibit_all_warnings!

target 'LightMedia' do
  # The playback engine. Handles HLS, MPEG-TS, MKV and the other formats providers send.
  pod 'MobileVLCKit', '3.6.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
      config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
    end
  end
end

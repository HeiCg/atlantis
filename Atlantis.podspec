Pod::Spec.new do |spec|
  spec.name         = "Atlantis"
  spec.version      = "1.1.1"
  spec.summary      = "A iOS framework for intercepting HTTP/HTTPS Traffic without Proxy and Certificate config"
  spec.description  = <<-DESC
  ✅ A iOS framework (Developed and Maintained by Proxyman Team) for intercepting HTTP/HTTPS Traffic from your app. No more messing around with proxy, certificate config.
  ✅ Automatically intercept all HTTP/HTTPS Traffic from your app
  ✅ No need to config HTTP Proxy, Install or Trust any Certificate
  Review Request/Response from Proxyman macOS
  Categorize the log by project and devices.

  This is the NetCapture-hardened fork (manual host + pinned-TLS collector v2 support),
  consumed by tag. See the argo-* tags.
                   DESC

  spec.homepage     = "https://github.com/HeiCg/atlantis"
  spec.documentation_url = "https://github.com/HeiCg/atlantis"
  spec.license      = { :type => "Apache License, Version 2.0", :file => "LICENSE" }

  spec.author             = { "Proxyman LLC" => "nghia@proxyman.com" }
  spec.social_media_url   = "https://x.com/proxyman_app"

  # Platforms match Package.swift.
  spec.ios.deployment_target = "13.0"
  spec.osx.deployment_target = "10.15"
  spec.tvos.deployment_target = "13.0"
  spec.watchos.deployment_target = "10.0"
  spec.visionos.deployment_target = "1.0"
  spec.module_name = "Atlantis"

  # Consumed by tag: the fork publishes argo-* release tags. s.version (1.1.1) is a
  # valid CocoaPods semver; the tag is pinned explicitly since it is not equal to it.
  spec.source       = { :git => "https://github.com/HeiCg/atlantis.git", :tag => "argo-1.1.1" }
  spec.source_files = "Sources/**/*.swift"

  # Ship the privacy manifest to CocoaPods consumers (SPM ships it as a resource too).
  spec.resource_bundles = { "Atlantis_Privacy" => ["Sources/PrivacyInfo.xcprivacy"] }

  spec.swift_versions = ["5.0"]
end

#!/usr/bin/env ruby
# scripts/add-pyramid-tests-target.rb
#
# 在 Pyramid.xcodeproj 里加一个 PyramidTests XCTest target，链接 XCTest，
# 依赖 Pyramid（PyramidTests 通过 @testable import Pyramid 访问 Pyramid
# 源码里的 MarkdownParser / MarkdownBlock / 等 internal 类型）。
#
# 用法（在 macOS 上跑）：
#   gem install xcodeproj
#   ruby scripts/add-pyramid-tests-target.rb
#   xcodebuild -project Pyramid.xcodeproj -list           # 验证 target 出现
#   xcodebuild -project Pyramid.xcodeproj -scheme PyramidTests \
#     -destination 'platform=iOS Simulator,name=iPhone 15' test
#
# 幂等：重复跑会跳过已存在的 target / build phase / 引用。

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Pyramid.xcodeproj', __dir__)
TEST_DIR_REL = 'PyramidTests'
TEST_FILE_REL = 'PyramidTests/MarkdownParserTests.swift'
TARGET_NAME = 'PyramidTests'
APP_TARGET_NAME = 'Pyramid'
BUNDLE_ID = 'com.pyramid.ios.tests'

project = Xcodeproj::Project.open(PROJECT_PATH)

# 1) 已经存在则退出（幂等）
existing = project.targets.find { |t| t.name == TARGET_NAME }
if existing
  puts "PyramidTests target already exists, nothing to do."
  exit 0
end

# 2) 找 Pyramid 主 target（依赖）
app_target = project.targets.find { |t| t.name == APP_TARGET_NAME }
raise "App target #{APP_TARGET_NAME} not found" unless app_target

# 3) 找或建 PyramidTests 文件组（Xcode Navigator 里能看到）
test_group = project.main_group[TARGET_NAME] || project.main_group.new_group(TARGET_NAME, TEST_DIR_REL)

# 4) 把测试源文件加进 group（不复制，路径直接指向仓库里的 PyramidTests/MarkdownParserTests.swift）
test_file_ref = test_group.files.find { |f| f.path == TEST_FILE_REL } ||
                test_group.new_reference(TEST_FILE_REL)

# 5) 建 target（com.apple.product-type.bundle.unit-test）
target = project.new_target(
  :unit_test_bundle,
  TARGET_NAME,
  :ios,
  '17.0',
  test_group,
  :swift
)
target.product_bundle_identifier = "#{BUNDLE_ID}.#{TARGET_NAME}"

# 6) Sources build phase：把测试文件加进去
sources = target.source_build_phase
sources.add_file_reference(test_file_ref)

# 7) Frameworks build phase：自动由 new_target 处理（PBXFrameworksBuildPhase 已建）
#    PyramidTests 通过 @testable import Pyramid 拿源码符号，无需额外 link。

# 8) 依赖 Pyramid（让 PyramidTests 的 host app = Pyramid.app）
target.add_dependency(app_target)
# hostApplication 设置（在 buildSettings 里）
target.build_configurations.each do |config|
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Pyramid.app/Pyramid'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = "#{BUNDLE_ID}.#{TARGET_NAME}"
end

# 9) 把 PyramidTests 加到 Pyramid scheme 的 Testables
#    xcodebuild 否则会报 "scheme is not currently configured for the test action"。
scheme = project.scheme(APP_TARGET_NAME)
unless scheme.test_targets.include?(target)
  scheme.add_test(target)
  puts "  → wired #{TARGET_NAME} into #{APP_TARGET_NAME} scheme Testables"
end

project.save

puts "✓ Added #{TARGET_NAME} target to #{PROJECT_PATH}"
puts "  Next steps:"
puts "    xcodebuild -project Pyramid.xcodeproj -list   # 验证"
puts "    xcodebuild -project Pyramid.xcodeproj -scheme Pyramid \\"
puts "      -destination 'platform=iOS Simulator,name=iPhone 15' test"

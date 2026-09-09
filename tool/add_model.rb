#!/usr/bin/env ruby
# Add a CoreML .mlpackage to the Runner target, without the Xcode drag-and-drop.
#
#   ruby tool/add_model.rb ~/Downloads/model_train/rfdetr/weld_rfdetr.mlpackage
#
# Uses the `xcodeproj` gem, which CocoaPods already depends on -- so if you have
# run `pod install` for this app, it is installed.
#
# The part that is easy to get wrong by hand: a CoreML model belongs in the
# target's SOURCES build phase, not Resources. Xcode runs `coremlc` over it as a
# build rule, producing the `.mlmodelc` that Bundle.main can find at runtime.
# Dropped into Resources instead, the raw .mlpackage is copied verbatim, no
# .mlmodelc is ever produced, and RFDetrRunner fails with `modelMissing`.
#
# Idempotent: running it twice does not duplicate the reference.

begin
  require 'xcodeproj'
rescue LoadError
  abort <<~MSG
    The `xcodeproj` gem is not available.
      sudo gem install xcodeproj
    (or run `pod install` in ios/ first — CocoaPods brings it in)
  MSG
end

MODEL_NAME = 'weld_rfdetr'   # must match RFDetrRunner's modelName in Swift

src = ARGV[0]
abort "usage: ruby tool/add_model.rb <path to .mlpackage>" if src.nil?

src = File.expand_path(src)
abort "not found: #{src}" unless File.exist?(src)
unless File.extname(src) == '.mlpackage'
  abort "expected a .mlpackage, got #{File.extname(src)}"
end

app_root  = File.expand_path('..', __dir__)
proj_path = File.join(app_root, 'ios', 'Runner.xcodeproj')
abort "no Xcode project at #{proj_path}" unless Dir.exist?(proj_path)

# The bundle must sit inside ios/Runner/ and be named exactly what the Swift
# asks for, because the lookup is by resource name.
dest = File.join(app_root, 'ios', 'Runner', "#{MODEL_NAME}.mlpackage")
if File.expand_path(src) != dest
  require 'fileutils'
  FileUtils.rm_rf(dest)
  FileUtils.cp_r(src, dest)   # .mlpackage is a directory, so copy recursively
  puts "copied  #{src}"
  puts "     -> #{dest}"
end

project = Xcodeproj::Project.open(proj_path)
target  = project.targets.find { |t| t.name == 'Runner' } or
  abort 'no target named Runner'
group = project.main_group['Runner'] or abort 'no Runner group'

basename = File.basename(dest)
existing = group.files.find { |f| f.display_name == basename }

if existing
  puts "reference already present: #{basename}"
  ref = existing
else
  ref = group.new_reference(dest)
  puts "added reference: #{basename}"
end

if target.source_build_phase.files_references.include?(ref)
  puts 'already in the Runner sources build phase'
else
  target.source_build_phase.add_file_reference(ref)
  puts 'added to the Runner sources build phase'
end

# A stale copy in Resources would ship the uncompiled bundle alongside the
# compiled one; drop it if a previous drag-and-drop put it there.
stale = target.resources_build_phase.files.select { |f| f.file_ref == ref }
unless stale.empty?
  stale.each { |f| target.resources_build_phase.remove_build_file(f) }
  puts 'removed a stale Resources entry (CoreML belongs in Sources)'
end

project.save
puts "\nsaved #{proj_path}"
puts "verify:  flutter build ios --debug --no-codesign"
puts "then:    find build -name '#{MODEL_NAME}.mlmodelc' -maxdepth 8"

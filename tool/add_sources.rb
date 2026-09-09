#!/usr/bin/env ruby
# Make sure every .swift in ios/Runner/ is actually compiled by the Runner target.
#
#   ruby tool/add_sources.rb
#
# A file written to ios/Runner/ by anything other than Xcode is invisible to the
# build: project.pbxproj lists sources explicitly, so the file sits on disk and
# the compiler never sees it. The symptom is "Cannot find 'X' in scope" from a
# file that *is* in the project, referring to a class in a file that is not.
#
# Idempotent, and it only ever adds -- nothing is removed, so a file Xcode
# already knows about is left alone.

begin
  require 'xcodeproj'
rescue LoadError
  abort <<~MSG
    The `xcodeproj` gem is not available.
      sudo gem install xcodeproj
    (or run `pod install` in ios/ first — CocoaPods brings it in)
  MSG
end

app_root  = File.expand_path('..', __dir__)
proj_path = File.join(app_root, 'ios', 'Runner.xcodeproj')
runner    = File.join(app_root, 'ios', 'Runner')
abort "no Xcode project at #{proj_path}" unless Dir.exist?(proj_path)

project = Xcodeproj::Project.open(proj_path)
target  = project.targets.find { |t| t.name == 'Runner' } or abort 'no target named Runner'
group   = project.main_group['Runner'] or abort 'no Runner group'

known = target.source_build_phase.files_references.map { |r| r.real_path.to_s }
added = 0

Dir.glob(File.join(runner, '*.swift')).sort.each do |path|
  name = File.basename(path)

  if known.include?(path)
    puts "  ok      #{name}"
    next
  end

  ref = group.files.find { |f| f.display_name == name } || group.new_reference(path)
  target.source_build_phase.add_file_reference(ref)
  puts "  ADDED   #{name}"
  added += 1
end

if added.zero?
  puts "\nnothing to do — every Swift file was already in the target"
else
  project.save
  puts "\nadded #{added} file(s); saved #{proj_path}"
end

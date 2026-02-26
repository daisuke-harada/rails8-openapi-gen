namespace :openapi do
  desc "Format generated and hand-written serializers with rufo (requires rufo gem)"
  task :format do
    dirs = [ "app/generated", "app/serializers" ].select { |d| Dir.exist?(d) }
    if dirs.empty?
      puts "no directories to format"
      next
    end
    cmd = [ "bundle", "exec", "rufo" ] + dirs
    puts "Running: #{cmd.join(' ')}"
    system(*cmd) || abort("rufo failed - ensure gem 'rufo' is installed and try bundle install")
  end

  desc "Generate code from OpenAPI and then format generated files (force with FORCE=true)"
  task :generate do
    force = ENV["FORCE"] == "true"
    cmd = [ "ruby", "script/openapi_codegen.rb" ]
    cmd << (force ? "--force" : "")
    cmd.reject!(&:empty?)
    puts "Running generator: #{cmd.join(' ')}"
    system(*cmd) || abort("generator failed")

    Rake::Task["openapi:format"].invoke
  end
end

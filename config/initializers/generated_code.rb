# Ensure generated code directory is autoloaded so generated classes are available
# This file is intentionally small and safe for development and production.
begin
  generated_dir = Rails.root.join("app", "generated").to_s
  FileUtils.mkdir_p(generated_dir) unless Dir.exist?(generated_dir)
  # Prefer registering with Zeitwerk (Rails autoloader) when available.
  if defined?(Rails.autoloaders) && Rails.autoloaders.respond_to?(:main)
    loader = Rails.autoloaders.main
    loader.push_dir(generated_dir) unless loader.dirs.include?(generated_dir)
  else
    # Fallback: try to append to config paths if not frozen. Guard against FrozenError.
    begin
      if Rails.application.config.respond_to?(:autoload_paths) && !Rails.application.config.autoload_paths.include?(generated_dir)
        Rails.application.config.autoload_paths << generated_dir
      end
      if Rails.application.config.respond_to?(:eager_load_paths) && !Rails.application.config.eager_load_paths.include?(generated_dir)
        Rails.application.config.eager_load_paths << generated_dir
      end
    rescue => inner_e
      # ignore silently; initializer should not break boot
      warn "generated_code initializer skipped (paths): #{inner_e.message}"
    end
  end
rescue => e
  # If Rails isn't fully loaded (e.g., when running script/openapi_codegen.rb directly), ignore silently.
  # This initializer should not break other rake tasks or generative scripts.
  warn "generated_code initializer skipped: #{e.message}"
end

# frozen_string_literal: true

# Generates Rails routes.rb from a resolved OpenAPI 3 spec.
#
# Usage:
#   ruby script/openapi_routes_generator.rb \
#     --spec api/resolved/openapi/openapi.yaml \
#     --out  config/routes.rb
#
# Notes / conventions:
# - Only generates routes for operations defined in `paths`.
# - Maps OpenAPI path params `{id}` => Rails `:id`.
# - Controller is derived from first tag if present, else from first path segment.
# - Action is derived from `operationId` when present, else from HTTP verb.
# - Output is deterministic (sorted by path, then method).
# - This script OVERWRITES the output file.

require "yaml"
require "optparse"
require "time"
require "fileutils"

HttpMethods = %w[get post put patch delete options head trace].freeze

options = {
  spec: "api/resolved/openapi/openapi.yaml",
  out: "config/routes.rb"
}

OptionParser.new do |opts|
  opts.on("--spec SPEC", "Path to resolved OpenAPI yaml") { |v| options[:spec] = v }
  opts.on("--out OUT", "Output routes file") { |v| options[:out] = v }
end.parse!(ARGV)

spec = YAML.load_file(options[:spec])
paths = spec.fetch("paths", {})

# controller naming helpers

def underscore(str)
  str
    .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
    .tr("-", "_")
    .downcase
end

def controller_from_operation(path, operation)
  tags = operation["tags"]
  if tags.is_a?(Array) && tags.first && !tags.first.to_s.empty?
    underscore(tags.first.to_s)
  else
    seg = path.to_s.split("/").reject(&:empty?).first
    underscore(seg || "api")
  end
end

def action_from_operation(operation, http_method)
  op_id = operation["operationId"]
  if op_id && !op_id.to_s.empty?
    # operationId can be like getWelcome, welcome_get, welcome.get
    sanitized = op_id.to_s.gsub(/[^a-zA-Z0-9_]/, "_")
    underscore(sanitized)
  else
    underscore(http_method)
  end
end

def rails_path(openapi_path)
  openapi_path.to_s.gsub(/\{([^}]+)\}/, ":\\1")
end

def camelize_controller(controller)
  controller.to_s.split("_").map { |p| p[0] ? p[0].upcase + p[1..] : p }.join + "Controller"
end

def controller_file_path(controller)
  File.join("app", "controllers", "#{controller}_controller.rb")
end

def method_defined_in?(ruby_source, method_name)
  ruby_source.match?(/^\s*def\s+#{Regexp.escape(method_name)}\b/)
end

entries = []

paths.each do |path, methods|
  next unless methods.is_a?(Hash)

  methods.each do |method, operation|
    method = method.to_s.downcase
    next unless HttpMethods.include?(method)
    next unless operation.is_a?(Hash)

    controller = controller_from_operation(path, operation)
    action = action_from_operation(operation, method)

    entries << {
      path: path.to_s,
      method: method,
      rails_path: rails_path(path),
      controller: controller,
      action: action,
      summary: operation["summary"],
      operation_id: operation["operationId"]
    }
  end
end

entries.sort_by! { |e| [ e[:path], e[:method] ] }

generated_at = Time.now.utc.iso8601

out = +"# frozen_string_literal: true\n"
out << "\n"
out << "# THIS FILE IS AUTO-GENERATED FROM OPENAPI. DO NOT EDIT BY HAND.\n"
out << "# Source: #{options[:spec]}\n"
out << "# Generated at: #{generated_at}\n"
out << "\n"
out << "Rails.application.routes.draw do\n"

entries.each do |e|
  comment_bits = []
  comment_bits << e[:summary].to_s.strip if e[:summary].to_s.strip != ""
  comment_bits << "operationId=#{e[:operation_id]}" if e[:operation_id].to_s.strip != ""
  out << "  # #{comment_bits.join(" | ")}\n" if comment_bits.any?
  out << "  #{e[:method]} \"#{e[:rails_path]}\" => \"#{e[:controller]}##{e[:action]}\"\n"
end

out << "end\n"

File.write(options[:out], out)

# ---- controller stub generation ----
# Non-destructive policy:
# - If controller file doesn't exist, create a minimal controller with all actions.
# - If it exists but action method is missing, append method stubs at the end of class.
# - Never overwrite existing method implementations.

controllers = entries.group_by { |e| e[:controller] }

controllers.each do |controller, controller_entries|
  klass = camelize_controller(controller)
  file_path = controller_file_path(controller)
  FileUtils.mkdir_p(File.dirname(file_path))

  actions = controller_entries.map { |e| e[:action] }.uniq.sort

  if !File.exist?(file_path)
    body = +"# frozen_string_literal: true\n\n"
    body << "class #{klass} < ApplicationController\n"
    actions.each do |action|
      body << "  def #{action}\n"
      # Minimal default: return 200 OK with JSON
      body << "    render json: { status: 'ok' }\n"
      body << "  end\n\n"
    end
    body << "end\n"
    File.write(file_path, body)
    next
  end

  existing = File.read(file_path)
  missing_actions = actions.reject { |a| method_defined_in?(existing, a) }
  next if missing_actions.empty?

  # Append missing methods just before final 'end' of the class if possible.
  insert = +"\n"
  missing_actions.each do |action|
    insert << "  def #{action}\n"
    insert << "    render json: { status: 'ok' }\n"
    insert << "  end\n\n"
  end

  if existing.match?(/^class\s+#{Regexp.escape(klass)}\b/) && existing.match?(/^end\s*$/)
    updated = existing.sub(/^end\s*$/) { |m| insert + m }
  else
    # Fallback: append at EOF
    updated = existing + insert
  end

  File.write(file_path, updated)
end

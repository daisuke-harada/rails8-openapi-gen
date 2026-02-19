require "yaml"
require "fileutils"
require "active_support/core_ext/string/inflections"
require "erb"

# 読み込むopenapiのpath
OPENAPI_PATH = "api/resolved/openapi/openapi.yaml".freeze

options = { force: false }

spec = YAML.load_file(OPENAPI_PATH)
paths = spec.fetch("paths", {})

# 許可する HTTP メソッドのリスト（path-item の他のキーを除外するため）
ALLOWED_HTTP_METHODS = %w[get post put patch delete options head].freeze

def controller_from_tags(path, operation)
  tags = operation["tags"]
  # タグをコントローラ名として使用します。タグがない場合は生成をスキップします。
  # tags は通常 OpenAPI の operation の tags (配列) で、最初の空でない要素を使います。
  return nil unless tags.is_a?(Array) && !tags.empty?
  tag = tags.find { |t| t && !t.to_s.strip.empty? }
  return nil unless tag
  # Rails/ActiveSupport の underscore を使う
  tag.to_s.underscore
end

def controller_file_path(controller)
  File.join("app", "controllers", "#{controller}_controller.rb")
end

# operationId 優先。なければ HTTP メソッド＋パスで推定
def action_name_for(path, http_method, operation)
  m = http_method.to_s.downcase
  # path が末尾パスパラメータかどうかで GET を index/show に分ける
  action = case m
  when "get"
    if path.match(%r{\{\w+\}\z}) || path.match(%r{/\:\w+\z}) # /{id} または /:id 相当
      "show"
    else
      "index"
    end
  when "post"   then "create"
  when "put"    then "update"
  when "patch"  then "update"
  when "delete" then "destroy"
  else
    # フォールバック: verb + normalized path
    normalized = path.gsub(/[\/{}]/, "_").gsub(/[^0-9a-z_]/i, "_").squeeze("_").strip
    "#{m}_#{normalized}".gsub(/_+/, "_").gsub(/\A_|_\z/, "").underscore
  end

  # メソッド優先。operationId は上書きの優先度を下げる（必要であれば将来ここで使える）
  action
end

# controller_actions: { controller_name => [action_name, ...] }
controller_actions = {}

paths.each do |path, methods|
  next unless methods.is_a?(Hash)
  methods.each do |method, op|
    m = method.to_s.downcase
    next unless ALLOWED_HTTP_METHODS.include?(m)
    next unless op && op.respond_to?(:[])
    ctrl = controller_from_tags(path, op)
    next unless ctrl

    action = action_name_for(path, m, op)
    controller_actions[ctrl] ||= []
    controller_actions[ctrl] << action unless controller_actions[ctrl].include?(action)
    # collect routes per controller for route file generation
    @controller_routes ||= {}
    @controller_routes[ctrl] ||= []
    # convert OpenAPI path parameters {id} -> :id for Rails route
    rails_path = path.gsub(/\{(.*?)\}/, ':\\1')
    @controller_routes[ctrl] << { verb: m, path: rails_path, action: action }
  end
end

# ファイル生成（存在するファイルは作らない）。アクション名でメソッドスタブを作る
controller_actions.each do |controller, actions|
  path = controller_file_path(controller)
  FileUtils.mkdir_p(File.dirname(path))

  class_name = controller.split('/').map(&:camelize).join('::') + 'Controller'

  # ---------- controller の生成 / 既存ファイルへの追記 ----------
  # 目的:
  # - OpenAPI の tags から得た controller 名ごとに、必要なアクションのメソッドスタブを
  #   コントローラファイルへ出力します。
  # - 既に存在するファイルは非破壊で扱い、欠落しているアクションのみを追記します。
  # - 新規に作成するファイルには必ず AUTO-GENERATED マーカーを含めておき、将来的に
  #   自動生成ファイルを識別・削除できるようにします。
  # 注意点:
  # - 既存のメソッドは上書きしません。手動で編集した実装を破壊しないための安全策です。
  # - 挿入はクラス定義の最後の `end` の直前に行います（正しい構文保持のため）。

  if File.exist?(path)
    # 既存ファイルには、存在しないアクションだけを自動生成（テンプレートの中身は参照しない）
    content = File.read(path)
    missing = actions.sort.reject { |a| content.match?(/^\s*def\s+#{Regexp.escape(a)}\b/) }
    if missing.empty?
      puts "exists: #{path} (all actions present)"
      next
    end

    methods_str = +""
    # If a developer-provided ERB template exists, use it to render method stubs.
    template_path = File.join('script', 'openapi_action_template.erb')
    if File.exist?(template_path)
      tpl = File.read(template_path)
      missing.each do |action|
        # Find a representative route for this action (if available) to populate template vars
        route = (@controller_routes && @controller_routes[controller]) ? @controller_routes[controller].find { |r| r[:action] == action } : nil
        locals = {
          action: action,
          controller: controller,
          path: route ? route[:path] : '',
          method: route ? route[:verb] : ''
        }
        # Use result_with_hash when available (Ruby 2.5+), fallback to basic ERB binding
        rendered = if ERB.instance_methods.include?(:result_with_hash)
                     ERB.new(tpl).result_with_hash(locals)
        else
                     # create a binding with local variables for ERB
                     b = binding
                     locals.each { |k, v| b.local_variable_set(k.to_sym, v) }
                     ERB.new(tpl).result(b)
        end
        methods_str << rendered
        methods_str << "\n" unless rendered.end_with?("\n")
      end
    else
      missing.each do |action|
        methods_str << "  def #{action}\n"
        methods_str << "    head :no_content\n"
        methods_str << "  end\n\n"
      end
    end

    # ensure methods_str starts/ends with a newline
    methods_str = "\n" + methods_str unless methods_str.start_with?("\n")
    methods_str << "\n" unless methods_str.end_with?("\n")

    # insert before the final `end` of the class regardless of preceding newline
    if content =~ /end\s*\z/
      content.sub!(/end\s*\z/, methods_str + "end\n")
    else
      content << "\n" + methods_str
    end

    File.write(path, content)
    puts "appended #{missing.size} action(s) to: #{path}"
  else
    # 新規作成: クラス定義と全アクションを出力（テンプレートは使わず stubs を作成）
    body = +"# frozen_string_literal: true\n"
    body << "# AUTO-GENERATED BY openapi_routes_generator - DO NOT EDIT MANUALLY\n"
    body << "class #{class_name} < ApplicationController\n\n"
    actions.sort.each do |action|
      body << "  def #{action}\n"
      body << "    head :no_content\n"
      body << "  end\n\n"
    end
    body << "end\n"
    File.write(path, body)
    puts "created: #{path}"
  end
end

routes_file = File.join('config', 'routes.rb')
FileUtils.mkdir_p(File.dirname(routes_file))
generated_block = "# BEGIN openapi routes - AUTO-GENERATED\n"

# ---------- routes の生成 ----------
# 目的:
# - OpenAPI から収集したコントローラごとのルート情報(@controller_routes)を基に
#   Rails の `config/routes.rb` を毎回上書きして出力します。
# - 単純化のため、既存の routes.rb は破棄して OpenAPI の定義に沿ったファイルを
#   毎回再生成します（ユーザの要求に基づく運用方針）。
# 安全性の留意点:
# - すべて上書きされるため、手動変更がある場合は事前にバックアップして下さい。
# - ルートパス中の OpenAPI パラメータ `{id}` は `:id` に変換済みです。

if defined?(@controller_routes) && @controller_routes
  @controller_routes.each do |ctrl, routes|
    routes.each do |r|
      verb = r[:verb]
      p = r[:path]
      action = r[:action]
      generated_block << "  #{verb} \"#{p}\" => \"#{ctrl}##{action}\"\n"
    end
  end
end
generated_block << "# END openapi routes - AUTO-GENERATED\n"

# 上書き出力: `config/routes.rb` を完全に再生成する
File.open(routes_file, 'w') do |f|
  f.puts "# THIS FILE IS AUTO-GENERATED FROM OPENAPI. DO NOT EDIT BY HAND."
  f.puts "# Source: #{OPENAPI_PATH}"
  f.puts "# Generated at: #{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
  f.puts "Rails.application.routes.draw do"
  if defined?(@controller_routes) && @controller_routes
    @controller_routes.each do |ctrl, routes|
      routes.each do |r|
        verb = r[:verb]
        p = r[:path]
        action = r[:action]
        # 例: get \"/up\" => \"health#index\"
        f.puts "  #{verb} \"#{p}\" => \"#{ctrl}##{action}\""
      end
    end
  end
  f.puts "end"
end
puts "wrote (overwrote) #{routes_file}"


# OpenAPI に存在しない自動生成ファイルを削除する
# 注意: 手動作成のファイルは誤削除しないよう、マーカーを含むファイルのみ削除対象とする
Dir.glob(File.join('app', 'controllers', '**', '*_controller.rb')).each do |file|
  next unless File.file?(file)
  base = File.basename(file, '.rb').sub(/_controller\z/, '')
  # application_controller などのルートは誤削除を防ぐ
  next if base == 'application'
  next if controller_actions.keys.include?(base)

  body = File.read(file)
  if body.include?('AUTO-GENERATED BY openapi_routes_generator')
    File.delete(file)
    puts "removed: #{file}"
  elsif options[:force]
    File.delete(file)
    puts "force-removed: #{file}"
  else
    puts "skipped (manual): #{file}"
  end
end

# operationId 優先。なければ HTTP メソッド＋パスで推定
def action_name_for(path, http_method, operation)
  m = http_method.to_s.downcase
  # path が末尾パスパラメータかどうかで GET を index/show に分ける
  action = case m
  when "get"
    if path.match(%r{\{\w+\}\z}) || path.match(%r{/\:\w+\z}) # /{id} または /:id 相当
      "show"
    else
      "index"
    end
  when "post"   then "create"
  when "put"    then "update"
  when "patch"  then "update"
  when "delete" then "destroy"
  else
  # フォールバック: verb + normalized path
  normalized = path.gsub(/[\/{}]/, "_").gsub(/[^0-9a-z_]/i, "_").squeeze("_").strip
    "#{m}_#{normalized}".gsub(/_+/, "_").gsub(/\A_|_\z/, "").underscore
  end

  # メソッド優先。operationId は上書きの優先度を下げる（必要であれば将来ここで使える）
  action
end

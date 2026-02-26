require "yaml"
require "fileutils"
require "active_support/core_ext/string/inflections"
require "erb"
require "digest/sha1"

# 読み込むopenapiのpath
OPENAPI_PATH = "api/resolved/openapi/openapi.yaml".freeze

# 出力先ディレクトリ（生成物はここに書く）
GENERATED_OUTPUT_DIR = File.expand_path("app/generated", Dir.pwd)
FileUtils.mkdir_p(GENERATED_OUTPUT_DIR) unless Dir.exist?(GENERATED_OUTPUT_DIR)

options = { force: false }

spec = YAML.load_file(OPENAPI_PATH)
paths = spec.fetch("paths", {})

# パスごとのローカルコンポーネントをマージする
# resolved ファイルに含まれていないローカルコンポーネントを読み込む
paths.keys.each do |path_key|
  # 例: /up -> api/paths/up.yaml
  path_file = File.join("api", "paths", "#{path_key.sub(/^\//, '')}.yaml")
  if File.exist?(path_file)
    path_spec = YAML.load_file(path_file)
    if path_spec && path_spec["components"]
      # componentsをspecにマージ
      spec["components"] ||= {}
      [ "schemas", "responses", "parameters" ].each do |component_type|
        if path_spec["components"][component_type]
          spec["components"][component_type] ||= {}
          spec["components"][component_type].merge!(path_spec["components"][component_type])
        end
      end
    end
  end
end

puts "DEBUG: Final merged schemas: #{spec.dig('components', 'schemas')&.keys.inspect}"

# 許可するHTTPメソッドのリスト（path-item の他のキーを除外するため）
ALLOWED_HTTP_METHODS = %w[get post put patch delete].freeze

def controller_from_tags(path, operation)
  tags = operation["tags"]
  # タグをコントローラ名として使用します。タグがない場合は生成をスキップします。
  # tags は通常 OpenAPI の operation の tags (配列) で、最初の空でない要素を使います。
  return nil unless tags.is_a?(Array) && !tags.empty?
  tag = tags.find { |t| t && !t.to_s.strip.empty? }
  return nil unless tag
  # Rails/ActiveSupportのunderscore を使う
  tag.to_s.underscore
end

def controller_file_path(controller)
  File.join("app", "controllers", "#{controller}_controller.rb")
end

def serializer_file_path(controller)
  file_name = "#{controller}_serializer.rb"
  File.join(GENERATED_OUTPUT_DIR, file_name)
end

# OpenAPI レスポンスからスキーマのプロパティを抽出する
def extract_schema_properties(spec, controller_name)
  # コントローラに関連するパスを探す
  paths = spec.fetch("paths", {})
  properties = []

  puts "DEBUG: Extracting schema for controller '#{controller_name}'"
  puts "DEBUG: Available paths: #{paths.keys.inspect}"
  puts "DEBUG: Available schemas: #{spec.dig('components', 'schemas')&.keys.inspect}"

  paths.each do |path, methods|
    next unless methods.is_a?(Hash)
    methods.each do |method, op|
      next unless ALLOWED_HTTP_METHODS.include?(method.to_s.downcase)
      next unless op && op.respond_to?(:[])

      # このパスがこのコントローラに属するか確認
      ctrl = controller_from_tags(path, op)
      puts "DEBUG: Path #{path} (#{method}) -> controller '#{ctrl}'"
      next unless ctrl == controller_name

      # レスポンスからスキーマを抽出
      responses = op["responses"] || {}
      puts "DEBUG: Responses for #{path}: #{responses.keys.inspect}"
      responses.each do |status, response|
        next unless status.start_with?("2") # 2xx responses only

        puts "DEBUG: Processing response #{status}: #{response.inspect[0..200]}"
        schema = extract_schema_from_response(response, spec)
        puts "DEBUG: Extracted schema: #{schema.inspect[0..200]}"
        next unless schema

        # プロパティを収集
        if schema["properties"]
          puts "DEBUG: Schema properties: #{schema['properties'].keys.inspect}"
          schema["properties"].each_key do |prop|
            properties << prop.to_sym unless properties.include?(prop.to_sym)
          end
        end
      end
    end
  end

  # Ensure unique and deterministic ordering: return symbols sorted by name
  properties.map(&:to_sym).uniq.sort_by(&:to_s)
end

# レスポンスからスキーマを取得（$ref を解決）
def schema_info_for_controller(spec, controller_name)
  paths = spec.fetch("paths", {})
  paths.each do |path, methods|
    next unless methods.is_a?(Hash)
    methods.each do |method, op|
      next unless ALLOWED_HTTP_METHODS.include?(method.to_s.downcase)
      next unless op && op.respond_to?(:[])
      ctrl = controller_from_tags(path, op)
      next unless ctrl == controller_name

      responses = op["responses"] || {}
      responses.each do |status, response|
        next unless status.to_s.start_with?("2")

        # response could be a $ref directly
        if response.is_a?(Hash) && response["$ref"]
          ref = response["$ref"]
          schema = resolve_ref(ref, spec)
          return [ schema, ref ] if schema
        end

        # content.application/json.schema
        if response.is_a?(Hash) && response["content"] && response["content"]["application/json"]
          schema = response["content"]["application/json"]["schema"]
          if schema && schema["$ref"]
            ref = schema["$ref"]
            s = resolve_ref(ref, spec)
            return [ s, ref ] if s
          elsif schema
            return [ schema, "#/paths#{path}/#{method}/responses/#{status}" ]
          end
        end

        # response could itself be a schema
        if response.is_a?(Hash) && (response["type"] || response["properties"])
          return [ response, "#/paths#{path}/#{method}/responses/#{status}" ]
        end
      end
    end
  end
  [ nil, nil ]
end

# レスポンスからスキーマを取得（$ref を解決）
def extract_schema_from_response(response, spec)
  # $ref があれば解決
  if response.is_a?(String) && response.start_with?("#/")
    ref_target = resolve_ref(response, spec)
    # $refが直接スキーマを指している場合（非標準だが許容）
    if ref_target && ref_target["type"]
      return ref_target
    end
    response = ref_target
  elsif response.is_a?(Hash) && response["$ref"]
    ref_target = resolve_ref(response["$ref"], spec)
    # $refが直接スキーマを指している場合
    if ref_target && ref_target["type"]
      return ref_target
    end
    response = ref_target
  end

  return nil unless response.is_a?(Hash)

  # content > application/json > schema を探す
  content = response["content"]
  if content && content["application/json"]
    schema = content["application/json"]["schema"]

    # schema の $ref を解決
    if schema && schema["$ref"]
      schema = resolve_ref(schema["$ref"], spec)
    end

    return schema
  end

  # contentがない場合、responseがschemaである可能性（非標準）
  if response["type"] || response["properties"]
    return response
  end

  nil
end

# $ref を解決する（例: "#/components/schemas/User" -> spec["components"]["schemas"]["User"]）
def resolve_ref(ref, spec)
  return nil unless ref.is_a?(String) && ref.start_with?("#/")

  path = ref.sub(/^#\//, "").split("/")
  result = spec
  path.each do |key|
    return nil unless result.is_a?(Hash)
    result = result[key]
  end
  result
end

# 抽出: 指定 operation から example を取得（2xx の最初のレスポンスを使用）
def extract_example_from_operation(op, spec)
  return nil unless op.is_a?(Hash)
  responses = op["responses"] || {}
  responses.each do |status, response|
    next unless status.to_s.start_with?("2")
    schema = extract_schema_from_response(response, spec)
    next unless schema
    ex = extract_example_from_schema(schema)
    return ex if ex
    # fallback: if properties have examples, build object
    if schema["properties"]
      obj = {}
      schema["properties"].each do |k, v|
        if v.is_a?(Hash) && v["example"]
          obj[k] = v["example"]
        else
          obj[k] = nil
        end
      end
      return obj unless obj.empty?
    end
  end
  nil
end

# スキーマから直接 example を抽出
def extract_example_from_schema(schema)
  return nil unless schema.is_a?(Hash)
  return schema["example"] if schema.key?("example")
  nil
end

# 指定コントローラの各アクションごとに example を収集して返す
def extract_examples_for_controller(spec, controller_name)
  result = {}
  paths = spec.fetch("paths", {})
  paths.each do |path, methods|
    next unless methods.is_a?(Hash)
    methods.each do |method, op|
      next unless ALLOWED_HTTP_METHODS.include?(method.to_s.downcase)
      next unless op && op.respond_to?(:[])
      ctrl = controller_from_tags(path, op)
      next unless ctrl == controller_name
      action = action_name_for(path, method, op)
      ex = extract_example_from_operation(op, spec)
      result[action.to_sym] = ex if ex
    end
  end
  result
end

# Ruby リテラルに変換（簡易）
def ruby_literal_for(obj)
  case obj
  when String
    obj.inspect
  when Numeric, TrueClass, FalseClass, NilClass
    obj.to_s
  when Array
    "[" + obj.map { |i| ruby_literal_for(i) }.join(", ") + "]"
  when Hash
    pairs = obj.map { |k, v| "#{k.to_s.inspect} => #{ruby_literal_for(v)}" }
    "{ " + pairs.join(", ") + " }"
  else
    obj.to_s.inspect
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
  @controller_routes[ctrl] << { verb: m, path: rails_path, action: action, openapi_path: path, http_method: m }
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
        # resolve operation object from merged spec if possible
        op = route && route[:openapi_path] && route[:http_method] ? spec.dig('paths', route[:openapi_path], route[:http_method]) : nil
        example_obj = op ? extract_example_from_operation(op, spec) : nil
        example_literal = example_obj ? ruby_literal_for(example_obj) : 'nil'
        serializer_class = controller.split('/').map(&:camelize).join('::') + 'Serializer'
        locals = {
          action: action,
          controller: controller,
          path: route ? route[:path] : '',
          method: route ? route[:verb] : '',
          serializer_class: serializer_class,
          example: example_literal
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
    # 新規作成: クラス定義と全アクションを出力（テンプレートがあれば使用）
    template_path = File.join('script', 'openapi_action_template.erb')
    if File.exist?(template_path)
      tpl = File.read(template_path)
      methods_str = +""
      actions.sort.each do |action|
        # Find a representative route for this action (if available) to populate template vars
        route = (@controller_routes && @controller_routes[controller]) ? @controller_routes[controller].find { |r| r[:action] == action } : nil
        # extract example for this operation
        op = route && route[:openapi_path] && route[:http_method] ? spec.dig('paths', route[:openapi_path], route[:http_method]) : nil
        example_obj = op ? extract_example_from_operation(op, spec) : nil
        example_literal = example_obj ? ruby_literal_for(example_obj) : 'nil'
        # Note: when creating, we may not have operation object; fallback to empty
        serializer_class = controller.split('/').map(&:camelize).join('::') + 'Serializer'
        locals = {
          action: action,
          controller: controller,
          path: route ? route[:path] : '',
          method: route ? route[:verb] : '',
          serializer_class: serializer_class,
          example: example_literal
        }
        if ERB.instance_methods.include?(:result_with_hash)
          rendered = ERB.new(tpl).result_with_hash(locals)
        else
          b = binding
          locals.each { |k, v| b.local_variable_set(k.to_sym, v) }
          rendered = ERB.new(tpl).result(b)
        end
        methods_str << rendered
        methods_str << "\n" unless rendered.end_with?("\n")
      end

      body = +"# frozen_string_literal: true\n"
      body << "# AUTO-GENERATED BY openapi_routes_generator - DO NOT EDIT MANUALLY\n"
      body << "class #{class_name} < ApplicationController\n\n"
      body << methods_str
      body << "end\n"
      File.write(path, body)
      puts "created: #{path}"
    else
      # テンプレートがない場合は従来のスタブ
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
end

# ---------- serializer の生成 ----------
# 目的:
# - 各コントローラに対応するシリアライザを app/serializers/ に自動生成します。
# - コントローラと同じ名前（例: health_controller -> health_serializer）で作成します。
# - OpenAPI のレスポンススキーマから属性を抽出して自動設定します。
# 注意点:
# - 既存のシリアライザファイルは上書きしません（手動編集の保護）。
# - 新規作成時には AUTO-GENERATED マーカーを含めます。

controller_actions.keys.each do |controller|
  serializer_path = serializer_file_path(controller)
  FileUtils.mkdir_p(File.dirname(serializer_path))

  class_name = controller.split('/').map(&:camelize).join('::') + 'Serializer'

  # OpenAPI レスポンスから属性を抽出（先に算出して既存ファイル更新時に使う）
  attributes = extract_schema_properties(spec, controller)
  schema_obj, schema_ref = schema_info_for_controller(spec, controller)
  schema_hash = schema_obj ? Digest::SHA1.hexdigest(YAML.dump(schema_obj)) : nil
  puts "DEBUG: Controller '#{controller}' extracted attributes: #{attributes.inspect}, schema_ref: #{schema_ref}, schema_hash: #{schema_hash}"

  # collect examples for actions (used to populate EXAMPLES block)
  raw_examples = extract_examples_for_controller(spec, controller)
  examples_literals = {}
  raw_examples.each { |k, v| examples_literals[k.to_s] = ruby_literal_for(v) }

  if File.exist?(serializer_path)
    # 既存のシリアライザには、存在しないアクションのみを追加する
    content = File.read(serializer_path)
    # Migration helper: if this file was previously generated into app/serializers (top-level class)
    # and we have moved generation to app/generated, convert this file into the generated namespace
    # and create a hand-editable wrapper in app/serializers.
    begin
      wrapper_dir = File.join('app', 'serializers')
      FileUtils.mkdir_p(wrapper_dir) unless Dir.exist?(wrapper_dir)
      wrapper_path = File.join(wrapper_dir, "#{controller}_serializer.rb")
      needs_migration = content.include?("AUTO-GENERATED BY openapi_codegen") && !content.match?(/class\s+Generated::/)
      if needs_migration
        puts "migrating existing generated serializer to namespaced generated/ + creating wrapper for: #{controller}"
        # create namespaced generated content
        new_generated = content.sub(/class\s+#{Regexp.escape(class_name)}\b/, "class Generated::#{class_name}")
        File.write(serializer_path, new_generated)
        # create or overwrite wrapper only if it is missing or itself auto-generated
        if !File.exist?(wrapper_path) || File.read(wrapper_path).include?("AUTO-GENERATED BY openapi_codegen")
          wrapper_body = <<~RUBY
            # frozen_string_literal: true
            # Hand-written serializer that wraps the generated serializer.
            # Customize behavior here; this file will NOT be overwritten by the generator.
            class #{class_name} < Generated::#{class_name}
              # Add custom methods or overrides below.
            end
          RUBY
          File.write(wrapper_path, wrapper_body)
          puts "created wrapper: #{wrapper_path}"
        else
          puts "wrapper exists and appears manual: #{wrapper_path} (skipped overwrite)"
        end
        # refresh content variable to the new generated content
        content = new_generated
      end
    rescue => e
      puts "migration for #{serializer_path} failed: #{e.message}"
    end
    # If schema changed, update generated attributes and header (non-destructive)
    existing_hash = content[/^# GENERATED-HASH:\s*([0-9a-f]+)/, 1]
    if schema_hash && existing_hash != schema_hash && content.include?("AUTO-GENERATED BY openapi_codegen")
      # prepare new attributes line (if any)
      if attributes && attributes.any?
        attrs_str = attributes.map { |a| ":#{a}" }.join(", ")
        new_attr_line = "  attributes #{attrs_str}"
      else
        new_attr_line = nil
      end

      # replace existing attributes line if present, otherwise insert after include JSONAPI::Serializer
      if content.match(/^\s*attributes\s+.*$/)
        if new_attr_line
          content.sub!(/^\s*attributes\s+.*$/, new_attr_line)
        else
          content.sub!(/^\s*attributes\s+.*$\n?/, "")
        end
      else
        if new_attr_line
          content.sub!(/(include JSONAPI::Serializer\s*\n)/, "\\1#{new_attr_line}\n")
        end
      end

      # update or insert GENERATED-FROM / GENERATED-HASH header
      if content.match(/^# GENERATED-HASH:/)
        content.sub!(/^# GENERATED-HASH:.*$/, "# GENERATED-HASH: #{schema_hash}")
      else
        insert_after = "# AUTO-GENERATED BY openapi_codegen - DO NOT EDIT MANUALLY\n"
        if content.include?(insert_after)
          content.sub!(insert_after, insert_after + "# GENERATED-FROM: #{schema_ref}\n# GENERATED-HASH: #{schema_hash}\n")
        else
          # prepend if not found
          content = "# GENERATED-FROM: #{schema_ref}\n# GENERATED-HASH: #{schema_hash}\n" + content
        end
        # EXAMPLES are not embedded into generated serializers by default.
        # If you want per-action example provisioning, put them into the hand-written
        # wrapper under app/serializers or provide examples at render time in controllers.
      end
    end
    missing = (controller_actions[controller] || []).sort.reject { |a| content.match?(/def\s+self\.#{Regexp.escape(a)}_response\b/) }
    if missing.empty?
      puts "exists: #{serializer_path} (all actions present)"
      next
    end

    methods_str = +""
    missing.each do |action|
      methods_str << "\n  def self.#{action}_response(data = nil)\n"
      methods_str << "    new(data || {}).serializable_hash\n"
      methods_str << "  end\n"
    end

    # 挿入はクラス定義の最後の `end` の直前に行う
    if content =~ /end\s*\z/
      content.sub!(/end\s*\z/, methods_str + "end\n")
    else
      content << "\n" + methods_str
    end

    File.write(serializer_path, content)
    puts "appended #{missing.size} action(s) to: #{serializer_path}"
    next
  end

  # 新規作成: 基本的なシリアライザクラスを出力
  # テンプレートが存在すれば使用、なければデフォルトのスタブを作成
  template_path = File.join('script', 'openapi_serializer_template.erb')

  # collect action list for this controller
  actions_for_controller = controller_actions[controller] || []
  # examples are intentionally not embedded into generated serializers; controllers or
  # hand-written wrappers should supply example data when needed.

  body = if File.exist?(template_path)
    tpl = File.read(template_path)
    # Use a generated namespace to avoid clobbering hand-written serializers.
    generated_class_name = "Generated::#{class_name}"
    locals = {
      class_name: generated_class_name,
      controller: controller,
      attributes: attributes,
      actions: actions_for_controller,
      action_examples: examples_literals
    }
    if ERB.instance_methods.include?(:result_with_hash)
      ERB.new(tpl).result_with_hash(locals)
    else
      b = binding
      locals.each { |k, v| b.local_variable_set(k.to_sym, v) }
      ERB.new(tpl).result(b)
    end
  else
    # デフォルトテンプレート (生成物は Generated::namespace を使う)
    generated_class_name = "Generated::#{class_name}"
    result = +"# frozen_string_literal: true\n"
    result << "# AUTO-GENERATED BY openapi_codegen - DO NOT EDIT MANUALLY\n"
    result << "class #{generated_class_name}\n"
    result << "  include JSONAPI::Serializer\n\n"
    if attributes.any?
      attrs_str = attributes.map { |a| ":#{a}" }.join(", ")
      result << "  attributes #{attrs_str}\n"
    else
      result << "  # TODO: Add appropriate attributes based on your model\n"
      result << "  # attributes :id, :name, :created_at, :updated_at\n"
    end
    result << "end\n"
    result
  end

  # If we computed a schema hash, embed GENERATED-FROM / GENERATED-HASH into the generated body
  if schema_hash
    if body.include?("# AUTO-GENERATED BY openapi_codegen - DO NOT EDIT MANUALLY")
      body.sub!("# AUTO-GENERATED BY openapi_codegen - DO NOT EDIT MANUALLY", "# AUTO-GENERATED BY openapi_codegen - DO NOT EDIT MANUALLY\n# GENERATED-FROM: #{schema_ref}\n# GENERATED-HASH: #{schema_hash}")
    else
      body = "# GENERATED-FROM: #{schema_ref}\n# GENERATED-HASH: #{schema_hash}\n" + body
    end
  end

  File.write(serializer_path, body)
  puts "created: #{serializer_path}"
  # Create a hand-editable wrapper in app/serializers if it doesn't exist.
  wrapper_dir = File.join('app', 'serializers')
  FileUtils.mkdir_p(wrapper_dir) unless Dir.exist?(wrapper_dir)
  wrapper_path = File.join(wrapper_dir, "#{controller}_serializer.rb")
  unless File.exist?(wrapper_path)
    wrapper_body = <<~RUBY
      # frozen_string_literal: true
      # Hand-written serializer that wraps the generated serializer.
      # Customize behavior here; this file will NOT be overwritten by the generator.
      class #{class_name} < Generated::#{class_name}
        # Add custom methods or overrides below.
      end
    RUBY
    File.write(wrapper_path, wrapper_body)
    puts "created wrapper: #{wrapper_path}"
  else
    puts "wrapper exists: #{wrapper_path} (skipped)"
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

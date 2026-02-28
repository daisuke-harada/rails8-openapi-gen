require "yaml"
require "erb"
require "fileutils"
require "ostruct"

module Openapi
  class CodeGenerator
    TEMPLATES_DIR   = Rails.root.join("lib/templates/openapi")
    GENERATED_DIR   = Rails.root.join("app/controllers/generated")
    CONTROLLERS_DIR = Rails.root.join("app/controllers")

    # 1つのリソース（例: users）に対するパース結果を保持するデータ構造
    #
    # @!attribute resource_name [String] リソース名（例: "users"）
    # @!attribute namespace [Array<String>] 名前空間セグメント（例: ["admin"] → Admin::）
    # @!attribute actions [Array<ActionInfo>] そのリソースに紐づくアクション一覧
    # @!attribute permit_params [Array<String>] Strong Parameters用のフィールド名一覧
    ResourceInfo = Data.define(:resource_name, :namespace, :actions, :permit_params)

    # 1つのアクションに対するパース結果を保持するデータ構造
    #
    # @!attribute name [String] Railsアクション名（例: "index"）
    # @!attribute http_method [String] HTTPメソッド（例: "get"）
    # @!attribute path [String] OpenAPIのパス（例: "/users/{id}"）
    # @!attribute operation_id [String, nil] OpenAPIのoperationId
    # @!attribute responses [Array<Hash>] レスポンス情報の配列
    ActionInfo = Data.define(:name, :http_method, :path, :operation_id, :responses)

    # HTTPメソッド × パスパターンから Rails アクションを決定するマッピング
    #
    # パターンの判定順序（上から優先）:
    #   1. /{id}/edit  → edit
    #   2. /{id}       → show / update / destroy
    #   3. /           → index / create
    ACTION_MAPPING = [
      # [パスがIDセグメントで終わるか, パスがeditで終わるか, HTTPメソッド] => アクション名
      { id_param: false, edit: true,  method: "get",    action: "edit"    },
      { id_param: true,  edit: false, method: "get",    action: "show"    },
      { id_param: true,  edit: false, method: "patch",  action: "update"  },
      { id_param: true,  edit: false, method: "put",    action: "update"  },
      { id_param: true,  edit: false, method: "delete", action: "destroy" },
      { id_param: false, edit: false, method: "get",    action: "index"   },
      { id_param: false, edit: false, method: "post",   action: "create"  }
    ].freeze

    # @param openapi_path [Pathname] OpenAPIファイルのパス
    # @param target_resources [Array<String>, nil] 対象リソース名（nilの場合は全リソース）
    def initialize(openapi_path:, target_resources: nil)
      @openapi_path     = openapi_path
      @target_resources = target_resources
      @spec             = nil
    end

    def run
      load_spec
      resources = parse_resources
      generate_controller_files(resources)
    end

    private

    # -----------------------------------------------------------------------
    # Step 1: YAMLの読み込み
    # -----------------------------------------------------------------------

    def load_spec
      puts "[INFO] OpenAPIファイルを読み込み中..."
      @spec = YAML.load_file(@openapi_path, permitted_classes: [ Symbol ])
      puts "[INFO] 読み込み完了"
    rescue Psych::SyntaxError => e
      puts "[ERROR] YAMLパースエラー: #{e.message}"
      exit 1
    end

    # -----------------------------------------------------------------------
    # Step 2: OpenAPIパーサー
    # -----------------------------------------------------------------------

    # OpenAPIのpathsセクションを解析し、ResourceInfo の配列を返す
    #
    # @return [Array<ResourceInfo>]
    def parse_resources
      # `paths` は OpenAPI の "paths" セクションを読み込んだ Hash です。
      # 例:
      # {
      #   "/users" => {
      #     "get" => { "operationId"=>"index", "responses"=>{...}, "parameters"=>[...] , "requestBody"=>{...} },
      #     "post"=> { ... },
      #     "parameters" => [ ... ]   # path レベルのパラメータ（省略可能）
      #   },
      #   "/users/{id}" => { "get"=>{...}, "put"=>{...} }
      # }
      # 各 operation ("get","post" 等) は Hash で、"parameters", "requestBody",
      # "responses", "operationId", "summary", "tags" 等を含みます。
      # このスクリプトでは `paths.each do |path, methods|` で走査し、
      # `methods` 内の HTTP メソッド（"get" 等）を処理します。
      paths = @spec["paths"] || {}

  # パスからリソース名でグルーピングして内部表現を作る
  # 手順:
  #  1. `parse_path_info(path)` でパスを { namespace:, resource_name: } に分解。抽出できないパスは無視。
  #  2. namespace + resource_name を結合したキーでグルーピング（例: ["admin", "users"] → "admin/users"）。
  #  3. path に定義された各 HTTP メソッド（"get"/"post" 等）を走査。path レベルの "parameters" キーはスキップする。
  #  4. `resolve_action(path, http_method)` により Rails 標準アクション名を決定。マッピングに存在しない組み合わせは無視する。
  #  5. 各アクションについて `ActionInfo` を作成して `actions` リストに追加する。
  #  6. `create` / `update` の場合は `extract_permit_params(operation)` で Strong Parameters 候補を抽出し、
  #     `permit_params` にマージする（重複は排除）。
  # `@target_resources` が設定されている場合は対象リソースのみ処理します。
  grouped = paths.each_with_object({}) do |(path, methods), acc|
        info = parse_path_info(path)
        next if info.nil?

        resource = info[:resource_name]
        namespace = info[:namespace]
        group_key = (namespace + [ resource ]).join("/")

        next if @target_resources && !@target_resources.include?(resource)

        methods.each do |http_method, operation_def|
          # パスパラメーター定義（"parameters"キー）はスキップ
          next if http_method == "parameters"

          action = resolve_action(path, http_method)
          next if action.nil?

          # レスポンス定義を解析（2xx優先で schema の properties を抽出）
          acc[group_key] ||= { resource_name: resource, namespace: namespace, actions: [], permit_params: [] }
          acc[group_key][:actions] << ActionInfo.new(
            name:         action,
            http_method:  http_method,
            path:         path,
            operation_id: operation_def["operationId"],
            responses: resolve_responses(operation_def["responses"])
          )

          # create / update は requestBody または parameters からパラメーターを抽出
          if %w[create update].include?(action)
            params = extract_permit_params(operation_def)
            acc[group_key][:permit_params] |= params
          end
        end
      end

      grouped.map do |_group_key, data|
        ResourceInfo.new(
          resource_name: data[:resource_name],
          namespace:     data[:namespace],
          actions:       data[:actions].uniq { |a| a.name },
          permit_params: data[:permit_params]
        )
      end
    end

    # パス文字列を namespace / resource_name / tail に分解する
    #
    # 分解ルール:
    #   - セグメントを順番に走査し、「リソース名とすべき固定セグメント」を決定する。
    #   - 末尾が "edit" でその直前が {param} の場合、"edit" は tail に属する（edit アクション）。
    #     この場合は "edit" を除いた最後の固定セグメントをリソース名とする。
    #   - それ以外は最後の固定セグメントをリソース名とする。
    #   - リソース名より前の固定セグメントを namespace とする。
    #   - リソース名より後のセグメント（{id}, edit 等）を tail とする。
    #
    # 例:
    #   "/users"                   => { namespace: [],          resource_name: "users", tail: [] }
    #   "/users/{id}"              => { namespace: [],          resource_name: "users", tail: ["{id}"] }
    #   "/users/{id}/edit"         => { namespace: [],          resource_name: "users", tail: ["{id}", "edit"] }
    #   "/admin/users"             => { namespace: ["admin"],   resource_name: "users", tail: [] }
    #   "/admin/users/{id}"        => { namespace: ["admin"],   resource_name: "users", tail: ["{id}"] }
    #   "/admin/users/{id}/edit"   => { namespace: ["admin"],   resource_name: "users", tail: ["{id}", "edit"] }
    #   "/up/{id}/hoge"            => { namespace: ["up"],      resource_name: "hoge",  tail: [] }
    #   "/up/hoge/{id}"            => { namespace: ["up"],      resource_name: "hoge",  tail: ["{id}"] }
    #   "/up/{id}/users/{user_id}" => { namespace: ["up"],      resource_name: "users", tail: ["{user_id}"] }
    #   "/admin/{id}/users"        => { namespace: ["admin"],   resource_name: "users", tail: [] }
    #   "/"                        => nil
    #
    # @param path [String]
    # @return [Hash, nil] { namespace: Array<String>, resource_name: String, tail: Array<String> }
    def parse_path_info(path)
      segments = path.split("/").reject(&:empty?)
      return nil if segments.empty?

      # 固定セグメント（{...} でない）のインデックスを全て取得
      fixed_indices = segments.each_index.select { |i| !segments[i].start_with?("{") }
      return nil if fixed_indices.empty?

      # --- edit の特殊処理 ---
      # 末尾セグメントが "edit" かつその直前が {param} の場合:
      #   "edit" は tail に含めるため、リソース名候補から除外する
      #   例: ["up", "{id}", "edit"] → fixed_indices から "edit" の index を除外して探す
      effective_fixed_indices = fixed_indices
      last_seg = segments.last
      second_last_seg = segments.length >= 2 ? segments[-2] : nil
      if last_seg == "edit" && second_last_seg&.match?(/\A\{.+\}\z/)
        # "edit" インデックスを除いた固定インデックスでリソースを決める
        effective_fixed_indices = fixed_indices[0..-2]
        return nil if effective_fixed_indices.empty?
      end

      # 最後の固定セグメント（edit 除外後）がリソース名
      resource_idx  = effective_fixed_indices.last
      resource_name = segments[resource_idx].gsub("-", "_")

      # リソース名より前の固定セグメントが namespace
      namespace = effective_fixed_indices[0..-2].map { |i| segments[i].gsub("-", "_") }

      # リソース名より後のセグメントが tail（{id}, edit 等）
      tail = segments[(resource_idx + 1)..]

      {
        namespace:     namespace,
        resource_name: resource_name,
        tail:          tail
      }
    end

    # HTTPメソッドとパスパターンから Rails アクション名を解決する
    #
    # @param path [String] OpenAPIのパス（例: "/users/{id}"）
    # @param http_method [String] HTTPメソッド（小文字, 例: "get"）
    # @return [String, nil] Railsアクション名。マッピングに存在しない場合は nil
    def resolve_action(path, http_method)
      info = parse_path_info(path)
      return nil unless info

      tail = info[:tail]
      # tail の末尾で edit / {id} を判定
      has_id_param   = tail.last&.match?(/\A\{.+\}\z/) || false
      ends_with_edit = tail.last == "edit"

      matched = ACTION_MAPPING.find do |rule|
        rule[:method] == http_method &&
          rule[:id_param] == has_id_param &&
          rule[:edit] == ends_with_edit
      end

      matched&.fetch(:action)
    end

    # responses ハッシュからスキーマ情報を抽出して配列で返す
    #
    # 各レスポンスエントリについて、content.application/json.schema が存在する場合に
    # そのスキーマを解決して { status:, schema_ref:, schema_name:, fields: } のハッシュを作り
    # 配列で返します。スキーマが見つからないエントリはスキップされます。
    #
    # @param responses [Hash] OpenAPI の responses 定義
    # @return [Array<Hash>] 抽出結果の配列（見つからなければ空配列）
    #   [
    #     { status: "200", schema_ref: "#/components/schemas/Foo", schema_name: "Foo", fields: [...] },
    #     ...
    #   ]
    def resolve_responses(responses)
      return [] unless responses.is_a?(Hash) && !responses.empty?

      responses.map do |status, resp|
        # content 内の JSON schema を探す
        schema = resp.dig("content", "application/json", "schema")
        next unless schema.is_a?(Hash)

        # $ref がある場合は解決する
        ref = schema["$ref"]
        resolved = ref ? (resolve_ref(ref) || schema) : schema

        # スキーマ名（$ref の末尾セグメント）
        schema_name = ref&.split("/")&.last

        # properties を再帰的に展開（extract_schema_params を再利用）
        fields = extract_schema_params(resolved)
        {
          status:      status,
          schema_ref:  ref,
          schema_name: schema_name,
          fields:      fields
        }
      end.compact
    end

    # operation定義からStrong Parameters用のフィールド名一覧を抽出する
    #
    # 優先順位:
    #   1. requestBody.content['application/json'].schema.properties
    #   2. parameters（query / body）のname
    #
    # readOnly: true のプロパティは除外する
    #
    # @param operation_def [Hash] OpenAPIのoperation定義
    # @return [Array<String>] フィールド名の配列
    def extract_permit_params(operation_def)
      params = []
      # --- requestBody から抽出 ---
      request_body = operation_def["requestBody"]
      if request_body
        schema = request_body
          .dig("content", "application/json", "schema") ||
          request_body.dig("content", "multipart/form-data", "schema")

        params.concat(extract_schema_params(schema)) if schema
      end

      # --- parameters から抽出（bodyスコープのみ） ---
      (operation_def["parameters"] || []).each do |param|
        next if %w[path query header cookie].include?(param["in"])

        params << param["name"] if param["name"]
      end

      params.uniq
    end

    # -----------------------------------------------------------------------
    # Step 4: Strong Parameters 生成ロジック
    # -----------------------------------------------------------------------

    # スキーマ定義からフィールドを再帰的に抽出する
    #
    # 返却値はネスト構造を保持した配列。各要素は以下のいずれか:
    #   - String          : スカラー値フィールド（例: "name"）
    #   - Hash            : ネストオブジェクト（例: { "address" => ["city", "zip"] }）
    #   - Hash with array : 配列フィールド（例: { "tags" => :array } または { "items" => ["id"] }）
    #
    # $ref が含まれる場合は components/schemas から実体を解決してから処理する。
    # 例: { "$ref" => "#/components/schemas/UpCreate" } → components["schemas"]["UpCreate"] の内容を使う
    #
    # @param schema [Hash] OpenAPIのschema定義
    # @return [Array<String, Hash>]
    def extract_schema_params(schema)
      return [] unless schema.is_a?(Hash)

      # $ref を解決する（例: "#/components/schemas/Foo" → @spec のその位置の Hash）
      schema = resolve_ref(schema["$ref"]) || return if schema["$ref"]

      # allOf / oneOf / anyOf の場合は全要素のプロパティをマージする
      composed = schema["allOf"] || schema["oneOf"] || schema["anyOf"]
      if composed
        merged_props = composed.each_with_object({}) do |sub, acc|
          # 各サブスキーマも $ref の可能性があるため解決してからマージ
          resolved = sub["$ref"] ? (resolve_ref(sub["$ref"]) || sub) : sub
          acc.merge!(resolved["properties"] || {})
        end
        return extract_properties(merged_props)
      end

      extract_properties(schema["properties"] || {})
    end

    # "#/components/schemas/Foo" 形式の $ref を @spec から辿って実体の Hash を返す
    #
    # @param ref [String] 例: "#/components/schemas/UpCreate"
    # @return [Hash, nil] 解決できた場合はその Hash、できない場合は nil
    def resolve_ref(ref)
      return nil unless ref.is_a?(String) && ref.start_with?("#/")

      # "#/" を除いて "/" で分割し、@spec を順番に掘り下げる
      # 例: "#/components/schemas/UpCreate" → ["components", "schemas", "UpCreate"]
      keys = ref.delete_prefix("#/").split("/")
      keys.reduce(@spec) { |node, key| node.is_a?(Hash) ? node[key] : nil }
    end

    # properties ハッシュから Strong Parameters 用フィールドリストを構築する
    #
    # @param properties [Hash] OpenAPI の properties 定義
    # @return [Array<String, Hash>]
    def extract_properties(properties)
      properties.filter_map do |name, definition|
        # $ref の場合は実体を解決してから処理
        definition = resolve_ref(definition["$ref"]) || next if definition.is_a?(Hash) && definition["$ref"]

        next if definition.is_a?(Hash) && definition["readOnly"] == true

        case definition["type"]
        when "object"
          # ネストオブジェクト → { "address" => ["city", "zip"] }
          nested = extract_schema_params(definition)
          nested.any? ? { name => nested } : name
        when "array"
          items = definition["items"]
          # items も $ref の可能性があるため解決する
          items = resolve_ref(items["$ref"]) || items if items.is_a?(Hash) && items["$ref"]
          if items.is_a?(Hash) && items["type"] == "object"
            # オブジェクト配列 → { "line_items" => ["product_id", "quantity"] }
            nested = extract_schema_params(items)
            nested.any? ? { name => nested } : { name => [] }
          else
            # スカラー配列 → { "tag_ids" => [] }
            { name => [] }
          end
        else
          # スカラー値 → "name"
          name
        end
      end
    end

    # permit_params の配列から `params.require(...).permit(...)` のコード文字列を生成する
    #
    # 例:
    #   build_strong_params_code("user", ["name", "email", { "address" => ["city", "zip"] }])
    #   # => 'params.require(:user).permit(:name, :email, address: [:city, :zip])'
    #
    # @param model_name [String] モデル名（例: "user"）
    # @param permit_params [Array<String, Hash>] extract_schema_params の返り値
    # @return [String]
    def build_strong_params_code(model_name, permit_params)
      if permit_params.empty?
        "params.require(:#{model_name})"
      else
        permit_str = build_permit_list(permit_params)
        "params.require(:#{model_name}).permit(#{permit_str})"
      end
    end

    # permit リストをコード文字列に変換する（再帰）
    #
    # @param params [Array<String, Hash>]
    # @return [String]
    def build_permit_list(params)
      params.map do |item|
        case item
        when String
          ":#{item}"
        when Hash
          item.map do |key, value|
            case value
            when Array
              if value.empty?
                # スカラー配列: tag_ids: []
                "#{key}: []"
              else
                # ネスト: address: [:city, :zip]
                nested = build_permit_list(value)
                "#{key}: [#{nested}]"
              end
            end
          end.join(", ")
        end
      end.join(", ")
    end

    # -----------------------------------------------------------------------
    # Step 5: ファイル生成
    # -----------------------------------------------------------------------

    # 全リソースのコントローラーファイルを生成する
    #
    # @param resources [Array<ResourceInfo>]
    def generate_controller_files(resources)
      if resources.empty?
        puts "[WARN] 対象リソースが見つかりませんでした"
        return
      end

      FileUtils.mkdir_p(GENERATED_DIR)
      FileUtils.mkdir_p(CONTROLLERS_DIR)

      resources.each do |resource|
        write_base_controller(resource)
        write_impl_controller(resource)
      end
    end

    # Baseコントローラーを生成する（毎回フル上書き）
    #
    # @param resource [ResourceInfo]
    def write_base_controller(resource)
      model_name      = resource.resource_name.singularize
      # namespace がある場合: Admin::UsersBaseController、ない場合: UsersBaseController
      base_class_name = (resource.namespace.map(&:camelize) + [ "#{resource.resource_name.camelize}BaseController" ]).join("::")

      # 出力先ディレクトリは namespace に合わせてサブディレクトリを作成
      dir       = GENERATED_DIR.join(*resource.namespace)
      FileUtils.mkdir_p(dir)
      file_path = dir.join("#{resource.resource_name}_base_controller.rb")

      content = render_template(
        "base_controller.erb",
        base_class_name:    base_class_name,
        namespace:          resource.namespace,
        model_name:         model_name,
        actions:            resource.actions,
        permit_params:      resource.permit_params,
        strong_params_code: build_strong_params_code(model_name, resource.permit_params)
      )

      File.write(file_path, content)
      puts "[上書き]  #{pretty_path(file_path)}"
    end

    # 実装コントローラーを生成する（存在しない場合のみ）
    #
    # @param resource [ResourceInfo]
    def write_impl_controller(resource)
      model_name      = resource.resource_name.singularize
      base_class_name = (resource.namespace.map(&:camelize) + [ "#{resource.resource_name.camelize}BaseController" ]).join("::")
      # namespace を含めた完全クラス名（例: Up::HogeController）
      impl_class_name = (resource.namespace.map(&:camelize) + [ "#{resource.resource_name.camelize}Controller" ]).join("::")

      # 出力先ディレクトリは namespace に合わせてサブディレクトリを作成
      dir       = CONTROLLERS_DIR.join(*resource.namespace)
      FileUtils.mkdir_p(dir)
      file_path = dir.join("#{resource.resource_name}_controller.rb")

      if file_path.exist?
        puts "[スキップ] #{pretty_path(file_path)} (既存ファイルを保護)"
        return
      end

      content = render_template(
        "impl_controller.erb",
        base_class_name: base_class_name,
        impl_class_name: impl_class_name,
        namespace:       resource.namespace,
        model_name:      model_name
      )

      File.write(file_path, content)
      puts "[新規作成] #{pretty_path(file_path)}"
    end

    # ERBテンプレートをレンダリングする
    #
    # @param template_name [String] テンプレートファイル名（例: "base_controller.erb"）
    # @param locals [Hash] テンプレートに渡すローカル変数
    # @return [String] レンダリング結果
    def render_template(template_name, **locals)
      template_path = TEMPLATES_DIR.join(template_name)

      unless template_path.exist?
        raise "テンプレートが見つかりません: #{template_path}"
      end

      template_str = File.read(template_path)

      # ERBのbindingにlocalsの変数を展開するためOpenStructを利用
      context = OpenStruct.new(locals) # rubocop:disable Style/OpenStructUse
      ERB.new(template_str, trim_mode: "-").result(context.instance_eval { binding })
    end

    # Rails.root からの相対パスで表示用パス文字列を返す
    #
    # @param path [Pathname]
    # @return [String]
    def pretty_path(path)
      path.relative_path_from(Rails.root).to_s
    end
  end
end

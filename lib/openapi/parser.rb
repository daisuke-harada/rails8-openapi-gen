module Openapi
  class Parser
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

    # @param spec [Hash] YAML.load_file で読み込んだ OpenAPI spec
    # @param target_resources [Array<String>, nil] 対象リソース名（nil の場合は全リソース）
    def initialize(spec, target_resources: nil)
      @spec             = spec
      @target_resources = target_resources
    end

    # OpenAPI の paths セクションを解析し、ResourceInfo の配列を返す
    #
    # @return [Array<ResourceInfo>]
    def parse_resources
      paths = @spec["paths"] || {}

      grouped = paths.each_with_object({}) do |(path, methods), acc|
        info = parse_path_info(path)
        next if info.nil?

        resource  = info[:resource_name]
        namespace = info[:namespace]
        group_key = (namespace + [ resource ]).join("/")

        next if @target_resources && !@target_resources.include?(resource)

        methods.each do |http_method, operation_def|
          # パスパラメーター定義（"parameters"キー）はスキップ
          next if http_method == "parameters"

          action = resolve_action(path, http_method)
          next if action.nil?

          acc[group_key] ||= { resource_name: resource, namespace: namespace, actions: [], permit_params: [] }
          acc[group_key][:actions] << ActionInfo.new(
            name:         action,
            http_method:  http_method,
            path:         path,
            operation_id: operation_def["operationId"],
            responses:    resolve_responses(operation_def["responses"])
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

    private

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

      fixed_indices = segments.each_index.select { |i| !segments[i].start_with?("{") }
      return nil if fixed_indices.empty?

      # --- edit の特殊処理 ---
      # 末尾セグメントが "edit" かつその直前が {param} の場合:
      # "edit" は tail に含めるため、リソース名候補から除外する
      effective_fixed_indices = fixed_indices
      last_seg        = segments.last
      second_last_seg = segments.length >= 2 ? segments[-2] : nil
      if last_seg == "edit" && second_last_seg&.match?(/\A\{.+\}\z/)
        effective_fixed_indices = fixed_indices[0..-2]
        return nil if effective_fixed_indices.empty?
      end

      resource_idx  = effective_fixed_indices.last
      resource_name = segments[resource_idx].gsub("-", "_")
      namespace     = effective_fixed_indices[0..-2].map { |i| segments[i].gsub("-", "_") }
      tail          = segments[(resource_idx + 1)..]

      { namespace: namespace, resource_name: resource_name, tail: tail }
    end

    # HTTPメソッドとパスパターンから Rails アクション名を解決する
    #
    # @param path [String] OpenAPIのパス（例: "/users/{id}"）
    # @param http_method [String] HTTPメソッド（小文字, 例: "get"）
    # @return [String, nil] Railsアクション名。マッピングに存在しない場合は nil
    def resolve_action(path, http_method)
      info = parse_path_info(path)
      return nil unless info

      tail           = info[:tail]
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
    # 各レスポンスエントリについて、content["application/json"]["schema"] が存在する場合に
    # そのスキーマを解決して { status:, schema_ref:, schema_name:, fields: } のハッシュを作り
    # 配列で返します。スキーマが見つからないエントリはスキップされます。
    #
    # @param responses [Hash] OpenAPI の responses 定義
    # @return [Array<Hash>] 抽出結果の配列（見つからなければ空配列）
    def resolve_responses(responses)
      return [] unless responses.is_a?(Hash) && !responses.empty?

      responses.map do |status, resp|
        schema = resp.dig("content", "application/json", "schema")
        next unless schema.is_a?(Hash)

        ref         = schema["$ref"]
        resolved    = ref ? (resolve_ref(ref) || schema) : schema
        schema_name = ref&.split("/")&.last
        fields      = extract_schema_params(resolved)

        { status: status, schema_ref: ref, schema_name: schema_name, fields: fields }
      end.compact
    end

    # operation 定義から Strong Parameters 用のフィールド名一覧を抽出する
    #
    # 優先順位:
    #   1. requestBody.content['application/json'].schema.properties
    #   2. parameters（query / body）の name
    #
    # readOnly: true のプロパティは除外する
    #
    # @param operation_def [Hash] OpenAPIのoperation定義
    # @return [Array<String>] フィールド名の配列
    def extract_permit_params(operation_def)
      params = []

      request_body = operation_def["requestBody"]
      if request_body
        schema = request_body.dig("content", "application/json", "schema") ||
                 request_body.dig("content", "multipart/form-data", "schema")
        params.concat(extract_schema_params(schema)) if schema
      end

      (operation_def["parameters"] || []).each do |param|
        next if %w[path query header cookie].include?(param["in"])

        params << param["name"] if param["name"]
      end

      params.uniq
    end

    # スキーマ定義からフィールドを再帰的に抽出する
    #
    # 返却値はネスト構造を保持した配列。各要素は以下のいずれか:
    #   - String : スカラー値フィールド（例: "name"）
    #   - Hash   : ネストオブジェクト（例: { "address" => ["city", "zip"] }）
    #
    # @param schema [Hash] OpenAPIのschema定義
    # @return [Array<String, Hash>]
    def extract_schema_params(schema)
      return [] unless schema.is_a?(Hash)

      schema = resolve_ref(schema["$ref"]) || return if schema["$ref"]

      composed = schema["allOf"] || schema["oneOf"] || schema["anyOf"]
      if composed
        merged_props = composed.each_with_object({}) do |sub, acc|
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
    # @return [Hash, nil]
    def resolve_ref(ref)
      return nil unless ref.is_a?(String) && ref.start_with?("#/")

      keys = ref.delete_prefix("#/").split("/")
      keys.reduce(@spec) { |node, key| node.is_a?(Hash) ? node[key] : nil }
    end

    # properties ハッシュから Strong Parameters 用フィールドリストを構築する
    #
    # @param properties [Hash] OpenAPI の properties 定義
    # @return [Array<String, Hash>]
    def extract_properties(properties)
      properties.filter_map do |name, definition|
        definition = resolve_ref(definition["$ref"]) || next if definition.is_a?(Hash) && definition["$ref"]

        next if definition.is_a?(Hash) && definition["readOnly"] == true

        case definition["type"]
        when "object"
          nested = extract_schema_params(definition)
          nested.any? ? { name => nested } : name
        when "array"
          items = definition["items"]
          items = resolve_ref(items["$ref"]) || items if items.is_a?(Hash) && items["$ref"]
          if items.is_a?(Hash) && items["type"] == "object"
            nested = extract_schema_params(items)
            nested.any? ? { name => nested } : { name => [] }
          else
            { name => [] }
          end
        else
          name
        end
      end
    end
  end
end

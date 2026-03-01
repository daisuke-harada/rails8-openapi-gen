require "yaml"
require_relative "parser"
require_relative "generators/controller"
require_relative "generators/serializer"

module Openapi
  class CodeGenerator
    # @param openapi_path [Pathname] OpenAPIファイルのパス
    # @param target_resources [Array<String>, nil] 対象リソース名（nil の場合は全リソース）
    def initialize(openapi_path:, target_resources: nil)
      @openapi_path     = openapi_path
      @target_resources = target_resources
    end

    def run
      spec      = load_spec
      resources = Parser.new(spec, target_resources: @target_resources).parse_resources
      Generators::Serializer.new(resources).run
      Generators::Controller.new(resources).run
    end

    private

    def load_spec
      puts "[INFO] OpenAPIファイルを読み込み中..."
      spec = YAML.load_file(@openapi_path, permitted_classes: [ Symbol ])
      puts "[INFO] 読み込み完了"
      spec
    rescue Psych::SyntaxError => e
      puts "[ERROR] YAMLパースエラー: #{e.message}"
      exit 1
    end
  end
end

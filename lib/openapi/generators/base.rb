require "erb"
require "fileutils"
require "ostruct"

module Openapi
  module Generators
    class Base
      TEMPLATES_DIR = Rails.root.join("lib/templates/openapi")

      # @param resources [Array<Openapi::Parser::ResourceInfo>]
      def initialize(resources)
        @resources = resources
      end

      # サブクラスで実装する
      def run
        raise NotImplementedError, "#{self.class}#run を実装してください"
      end

      private

      # namespace + resource_name + suffix からクラス名文字列を生成する
      #
      # 例: namespace: ["admin"], resource_name: "users", suffix: "BaseController"
      #     => "Admin::UsersBaseController"
      #
      # @param resource [Openapi::Parser::ResourceInfo]
      # @param suffix [String]
      # @return [String]
      def class_name(resource, suffix:)
        (resource.namespace.map(&:camelize) + [ "#{resource.resource_name.camelize}#{suffix}" ]).join("::")
      end

      # ERBテンプレートをレンダリングする
      #
      # @param template_name [String] テンプレートファイル名（例: "base_controller.erb"）
      # @param locals [Hash] テンプレートに渡すローカル変数
      # @return [String] レンダリング結果
      def render_template(template_name, **locals)
        template_path = TEMPLATES_DIR.join(template_name)
        raise "テンプレートが見つかりません: #{template_path}" unless template_path.exist?

        template_str = File.read(template_path)
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
end

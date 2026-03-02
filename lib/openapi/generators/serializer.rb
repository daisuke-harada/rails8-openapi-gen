require_relative "base"

module Openapi
  module Generators
    class Serializer < Base
      GENERATED_DIR   = Rails.root.join("app/serializers/generated")
      SERIALIZERS_DIR = Rails.root.join("app/serializers")

      def run
        if @resources.empty?
          puts "[WARN] 対象リソースが見つかりませんでした"
          return
        end

        FileUtils.mkdir_p(GENERATED_DIR)
        FileUtils.mkdir_p(SERIALIZERS_DIR)

        @resources.each do |resource|
          resource.actions.each do |action|
            write_base_serializer(resource, action)
            write_impl_serializer(resource, action)
          end
        end
      end

      private

      # アクション別 BaseSerializer を生成する（毎回フル上書き）
      #
      # ディレクトリ構造:
      #   /up            → generated/ups/index_base_serializer.rb
      #   /up/{id}/users → generated/ups/users/index_base_serializer.rb
      #
      # @param resource [Openapi::Parser::ResourceInfo]
      # @param action [Openapi::Parser::ActionInfo]
      def write_base_serializer(resource, action)
        base_class_name = action_class_name(resource, action, suffix: "BaseSerializer")
        modules         = serializer_modules(resource)

        dir = GENERATED_DIR.join(*serializer_dir_segments(resource))
        FileUtils.mkdir_p(dir)
        file_path = dir.join("#{action.name}_base_serializer.rb")

        attributes = action.responses
                           .select { |r| r[:status].to_s.start_with?("2") }
                           .flat_map { |r| flatten_field_names(r[:fields]) }
                           .uniq

        content = render_template(
          "base_serializer.erb",
          base_class_name: base_class_name,
          modules:         modules,
          attributes:      attributes,
        )

        File.write(file_path, content)
        puts "[上書き]  #{pretty_path(file_path)}"
      end

      # アクション別 Serializer（impl）を生成する（存在しない場合のみ）
      #
      # @param resource [Openapi::Parser::ResourceInfo]
      # @param action [Openapi::Parser::ActionInfo]
      def write_impl_serializer(resource, action)
        base_class_name = action_class_name(resource, action, suffix: "BaseSerializer")
        impl_class_name = action_class_name(resource, action, suffix: "Serializer")
        modules         = serializer_modules(resource)

        dir = SERIALIZERS_DIR.join(*serializer_dir_segments(resource))
        FileUtils.mkdir_p(dir)
        file_path = dir.join("#{action.name}_serializer.rb")

        if file_path.exist?
          puts "[スキップ] #{pretty_path(file_path)} (既存ファイルを保護)"
          return
        end

        content = render_template(
          "impl_serializer.erb",
          base_class_name: base_class_name,
          impl_class_name: impl_class_name,
          modules:         modules,
        )

        File.write(file_path, content)
        puts "[新規作成] #{pretty_path(file_path)}"
      end

      # Serializer のディレクトリセグメントを返す
      #
      # 例:
      #   resource_name: "up",    namespace: []       → ["ups"]
      #   resource_name: "users", namespace: ["up"]   → ["ups", "users"]
      #
      # @param resource [Openapi::Parser::ResourceInfo]
      # @return [Array<String>]
      def serializer_dir_segments(resource)
        [ resource.resource_name.pluralize, *resource.namespace ]
      end

      # モジュール階層を返す（Generated 含まず）
      #
      # 例:
      #   resource_name: "up",    namespace: []       → ["Ups"]
      #   resource_name: "users", namespace: ["up"]   → ["Ups", "Users"]
      #
      # @param resource [Openapi::Parser::ResourceInfo]
      # @return [Array<String>]
      def serializer_modules(resource)
        [ resource.resource_name.pluralize.camelize, *resource.namespace.map(&:camelize) ]
      end

      # アクション別クラス名を生成する（モジュール修飾なし・短いクラス名のみ）
      #
      # 例:
      #   resource_name: "up",    action: "index",  suffix: "BaseSerializer" → "Up::IndexBaseSerializer"
      #   resource_name: "users", action: "create", suffix: "Serializer"     → "Users::CreateSerializer"
      #   namespace: ["up"], resource_name: "users", action: "index"         → "Ups::Users::IndexBaseSerializer"
      #
      # @param resource [Openapi::Parser::ResourceInfo]
      # @param action [Openapi::Parser::ActionInfo]
      # @param suffix [String]
      # @return [String]
      def action_class_name(resource, action, suffix:)
        parts = serializer_modules(resource) + [ "#{action.name.camelize}#{suffix}" ]
        parts.join("::")
      end

      # fields 配列からスカラーフィールド名のみをフラットに返す
      #
      # fields は String または { "key" => [...] } の Hash の混在配列。
      # Serializer の attributes にはスカラーフィールド名のみ必要なので、
      # Hash の場合はそのキー名だけを取り出す。
      #
      # 例:
      #   ["id", "title", { "articles" => ["id", "title"] }] → ["id", "title", "articles"]
      #
      # @param fields [Array<String, Hash>]
      # @return [Array<String>]
      def flatten_field_names(fields)
        fields.flat_map do |field|
          case field
          when String then field
          when Hash   then field.keys
          end
        end.compact
      end
    end
  end
end

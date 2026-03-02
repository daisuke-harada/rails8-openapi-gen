require_relative "base"

module Openapi
  module Generators
    class Routes < Base
      ROUTES_FILE = Rails.root.join("config/routes/openapi.rb")

      def run
        if @resources.empty?
          puts "[WARN] 対象リソースが見つかりませんでした"
          return
        end

        route_tree  = build_route_tree(@resources)
        route_lines = render_nodes(route_tree, indent: 0)

        content = render_template(
          "routes.erb",
          route_lines: route_lines,
        )

        File.write(ROUTES_FILE, content)
        puts "[上書き]  #{pretty_path(ROUTES_FILE)}"
      end

      private

      # ResourceInfo の配列からルーティングツリーを構築する
      #
      # namespace セグメントが他リソースの resource_name と一致する → nested resources
      # namespace セグメントが他リソースの resource_name と一致しない → module namespace
      #
      # 変換例:
      #   namespace: [],          resource: "users"  → resources :users
      #   namespace: ["admin"],   resource: "users"  → namespace :admin { resources :users }
      #   namespace: ["up"],      resource: "users"  → resources :ups { resources :users }
      #   namespace: ["admin","up"], resource: "users" → namespace :admin { resources :ups { resources :users } }
      #
      # @param resources [Array<Openapi::Parser::ResourceInfo>]
      # @return [Array<Hash>]
      def build_route_tree(resources)
        all_resource_names = resources.map(&:resource_name).to_set

        # キー: "ns1/ns2/resource_name" → ノード Hash
        nodes = resources.each_with_object({}) do |resource, acc|
          key = (resource.namespace + [ resource.resource_name ]).join("/")
          acc[key] = {
            name:              resource.resource_name,
            actions:           resource.actions.map(&:name).uniq,
            namespace:         resource.namespace,
            module_namespace:  resource.namespace.reject { |seg| all_resource_names.include?(seg) },
            parent_resources:  resource.namespace.select { |seg| all_resource_names.include?(seg) },
            children:          []
          }
        end

        # 親子関係を構築
        roots = []
        nodes.each do |_key, node|
          parent_resources = node[:parent_resources]

          if parent_resources.empty?
            roots << node
          else
            # 最も近い親リソースノードを探す
            parent_key = (node[:module_namespace] + parent_resources).join("/")
            parent_node = nodes[parent_key]
            if parent_node
              parent_node[:children] << node
            else
              roots << node
            end
          end
        end

        roots
      end

      # ノード配列を再帰的にルーティング行の配列として返す
      #
      # @param nodes [Array<Hash>]
      # @param indent [Integer]
      # @param inside_namespace [Boolean] すでに namespace ブロック内にいるか
      # @return [Array<String>]
      def render_nodes(nodes, indent:, inside_namespace: false)
        lines = []

        if inside_namespace
          # namespace ブロック内では module_namespace は無視してフラットに並べる
          nodes.each { |node| lines.concat(render_resource(node, indent: indent, inside_namespace: true)) }
        else
          # module namespace でグループ化
          grouped = nodes.group_by { |n| n[:module_namespace] }

          grouped.each do |ns, ns_nodes|
            if ns.empty?
              ns_nodes.each { |node| lines.concat(render_resource(node, indent: indent)) }
            else
              # namespace ブロックで包む
              ns.each_with_index do |seg, i|
                lines << "#{"  " * (indent + i)}namespace :#{seg} do"
              end
              inner_indent = indent + ns.size
              ns_nodes.each { |node| lines.concat(render_resource(node, indent: inner_indent, inside_namespace: true)) }
              ns.size.times { |i| lines << "#{"  " * (indent + ns.size - 1 - i)}end" }
            end
          end
        end

        lines
      end

      # 1つのリソースノードをルーティング行の配列として返す
      #
      # controller: オプションの付与ルール:
      #   - namespace ブロック外 かつ 親リソースあり → controller: 必要
      #     （resources ネストは自動でモジュールを解決しないため）
      #     例: resources :articles { resources :comments }
      #         → CommentsController を探してしまうため
      #         → controller: "articles/comments" で Articles::CommentsController を指定
      #   - namespace ブロック内 → controller: 不要
      #     （namespace が自動でモジュールを付けるため）
      #     例: namespace :admin { resources :posts { resources :tags } }
      #         → Admin::TagsController を自動で解決する
      #
      # @param node [Hash]
      # @param indent [Integer]
      # @param inside_namespace [Boolean] すでに namespace ブロック内にいるか
      # @return [Array<String>]
      def render_resource(node, indent:, inside_namespace: false)
        pad  = "  " * indent
        only = node[:actions].map { |a| " :#{a}" }.join(",")

        # namespace 外 かつ 親リソースあり → controller: を明示
        controller_option = if !inside_namespace && node[:parent_resources].any?
          path = (node[:module_namespace] + node[:parent_resources] + [ node[:name] ]).join("/")
          ", controller: \"#{path}\""
        else
          ""
        end

        if node[:children].empty?
          [ "#{pad}resources :#{node[:name]}, only: [#{only}]#{controller_option}" ]
        else
          [
            "#{pad}resources :#{node[:name]}, only: [#{only}]#{controller_option} do",
            *render_nodes(node[:children], indent: indent + 1, inside_namespace: inside_namespace),
            "#{pad}end"
          ]
        end
      end
    end
  end
end

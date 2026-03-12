namespace :openapi do
  desc <<~DESC
    OpenAPI仕様書からRailsコントローラーを自動生成する

    使用方法:
      bundle exec rake openapi:generate_code
      bundle exec rake openapi:generate_code[users]        # 特定リソースのみ
      bundle exec rake openapi:generate_code[users,posts]  # 複数リソース指定
  DESC
  task :generate_code, [ :resources ] => :environment do |_task, args|
    openapi_path = Rails.root.join("api/resolved/openapi/openapi.yaml")

    unless File.exist?(openapi_path)
      puts "[ERROR] OpenAPIファイルが見つかりません: #{openapi_path}"
      exit 1
    end

    # 対象リソースの絞り込み（未指定の場合は全リソース対象）
    target_resources = args[:resources]&.split(",")&.map(&:strip)

    puts "=" * 60
    puts "OpenAPI Controller Generator"
    puts "=" * 60
    puts "OpenAPIファイル: #{openapi_path}"
    puts "対象リソース: #{target_resources&.join(', ') || '全リソース'}"
    puts "=" * 60

    generator = Openapi::CodeGenerator.new(
      openapi_path: openapi_path,
      target_resources: target_resources
    )

    generator.run

    puts "=" * 60
    puts "生成完了"
    puts "=" * 60
  end
end

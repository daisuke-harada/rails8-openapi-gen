Rails.application.routes.draw do
  # 自動生成ルート（config/routes.openapi.rb）
  eval(File.read(Rails.root.join("config/routes.openapi.rb")), binding, "config/routes.openapi.rb", 1)
end

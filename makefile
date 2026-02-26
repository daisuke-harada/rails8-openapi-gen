oapi-gen:
	bash script/openapi-generator-cli.sh
	ruby script/openapi_codegen.rb --spec api/resolved/openapi/openapi.yaml --out config/routes.rb

setup-docker: oapi-gen
	@echo "==> Running oapi-gen and setting up app (docker)"
	docker compose run --rm app bundle install
	docker compose run --rm app bin/rails db:create db:migrate

setup: setup-docker
	@echo "Setup complete (docker)"
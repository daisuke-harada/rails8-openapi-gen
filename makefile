gen:
	bash script/openapi-generator-cli.sh

gen-controllers: gen
	@echo "==> Generating Rails controllers from OpenAPI (resolved -> controllers)"
	# Run the Rake task inside the app container to ensure correct gems/env
	docker compose run --rm app bundle exec rake openapi:generate_code

setup-docker: gen
	@echo "==> Running gen and setting up app (docker)"
	docker compose run --rm app bundle install
	docker compose run --rm app bin/rails db:create db:migrate

setup: setup-docker
	@echo "Setup complete (docker)"
gen:
	bash script/openapi-generator-cli.sh

code-gen:
	bundle exec rake openapi:generate_code

gen-all: gen code-gen

setup-docker: gen
	@echo "==> Running gen and setting up app (docker)"
	docker compose run --rm app bundle install
	docker compose run --rm app bin/rails db:create db:migrate

setup: setup-docker
	@echo "Setup complete (docker)"
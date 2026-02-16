oapi-gen:
	bash script/openapi-generator-cli.sh
	ruby script/openapi_routes_generator.rb --spec api/resolved/openapi/openapi.yaml --out config/routes.rb
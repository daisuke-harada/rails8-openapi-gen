oapi-gen:
	bash script/openapi-generator-cli.sh
	ruby script/openapi_codegen.rb --spec api/resolved/openapi/openapi.yaml --out config/routes.rb
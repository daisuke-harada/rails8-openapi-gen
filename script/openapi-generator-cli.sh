docker run --rm -v ${PWD}:/local openapitools/openapi-generator-cli generate \
    -i /local/api/OpenAPI.yaml \
    -g openapi-yaml \
    -o /local/api/resolved
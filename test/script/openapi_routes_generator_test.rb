# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"

class OpenapiRoutesGeneratorTest < Minitest::Test
  def test_generates_basic_route_from_openapi
    Dir.mktmpdir do |dir|
      spec_path = File.join(dir, "openapi.yaml")
      out_path = File.join(dir, "routes.rb")

      File.write(
        spec_path,
        <<~YAML
          openapi: 3.0.3
          info:
            title: Test
            version: 0.0.1
          paths:
            /welcome:
              get:
                tags: [health]
                operationId: getWelcome
                responses:
                  "200":
                    description: ok
        YAML
      )

      system(
        "ruby",
        "script/openapi_routes_generator.rb",
        "--spec",
        spec_path,
        "--out",
        out_path,
        exception: true
      )

      content = File.read(out_path)
      assert_includes content, 'get "/welcome" => "health#get_welcome"'
    end
  end

  def test_converts_path_params
    Dir.mktmpdir do |dir|
      spec_path = File.join(dir, "openapi.yaml")
      out_path = File.join(dir, "routes.rb")

      File.write(
        spec_path,
        <<~YAML
          openapi: 3.0.3
          info:
            title: Test
            version: 0.0.1
          paths:
            /users/{id}:
              delete:
                tags: [users]
                responses:
                  "204":
                    description: no content
        YAML
      )

      system(
        "ruby",
        "script/openapi_routes_generator.rb",
        "--spec",
        spec_path,
        "--out",
        out_path,
        exception: true
      )

      content = File.read(out_path)
      assert_includes content, 'delete "/users/:id" => "users#delete"'
    end
  end
end

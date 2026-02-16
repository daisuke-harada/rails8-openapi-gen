# frozen_string_literal: true

# THIS FILE IS AUTO-GENERATED FROM OPENAPI. DO NOT EDIT BY HAND.
# Source: api/resolved/openapi/openapi.yaml
# Generated at: 2026-02-16T15:12:54Z

Rails.application.routes.draw do
  # Health check | operationId=railsHealthCheck
  get "/up" => "health#rails_health_check"
end

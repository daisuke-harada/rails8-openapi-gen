# frozen_string_literal: true

class HealthController < ApplicationController
  def rails_health_check
    render json: { status: "ok" }
  end
end

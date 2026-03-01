# frozen_string_literal: true

# ==============================================================================
# このファイルは自動生成されます。手動で編集しないでください。
# 生成元: api/resolved/openapi/openapi.yaml
# ==============================================================================

module Generated
  class UpBaseController < ApplicationController
    # --------------------------------------------------------------------------
    # Actions
    # --------------------------------------------------------------------------

    # GET /up (operationId: up)

    def index
      resource = OpenStruct.new(message: "I'm up!", test: 123)
      render json: Ups::IndexSerializer.new(resource).serialize, status: :ok
    end

    # POST /up (operationId: upPost)

    def create
      resource = OpenStruct.new(tester: "I'm up!")
      render json: Ups::CreateSerializer.new(resource).serialize, status: :created
    end

    private

    # Strong Parameters
    def up_params
      params.require(:up).permit(:test)
    end

  end
end

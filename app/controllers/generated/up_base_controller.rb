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
      raise NotImplementedError, "UpBaseController#index は未実装です"
    end

    # POST /up (operationId: upPost)

    def create
      raise NotImplementedError, "UpBaseController#create は未実装です"
    end


    private

    # Strong Parameters
    def up_params
      params.require(:up).permit(:test)
    end

  end
end

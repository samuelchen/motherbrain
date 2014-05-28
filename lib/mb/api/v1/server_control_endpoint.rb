module MotherBrain::API
  class V1
    class ServerControlEndpoint < MB::API::Endpoint
      helpers MB::Mixin::Services

      desc "resume the server, preventing new requests from being processed"
      put 'resume' do
        MB::Application.resume
        server_status
      end

      desc "pause the server, preventing new requests from being processed"
      put 'pause' do
        MB::Application.pause
        server_status
      end

      desc "get the server status"
      get 'status' do
        server_status
      end

      helpers do
        def server_status
          {server_status: MB::Application.paused? ? "paused" : "running"}
        end
      end
    end
  end
end
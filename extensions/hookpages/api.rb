#
# Hook Page Generator – API registration
# Mounts the page-serving handler, the REST endpoint, and the miner control API.
#
module BeEF
  module Extension
    module Hookpages
      module RegisterHttpHandlers
        BeEF::API::Registrar.instance.register(
          BeEF::Extension::Hookpages::RegisterHttpHandlers,
          BeEF::API::Server,
          'mount_handler'
        )

        def self.mount_handler(beef_server)
          beef_server.mount('/hookpages',           BeEF::Extension::Hookpages::Handler.new)
          beef_server.mount('/api/hookpages',       BeEF::Extension::Hookpages::HookpagesRest.new)
          beef_server.mount('/api/hookpages/miner', BeEF::Extension::Hookpages::MinerControlRest.new)
        end
      end
    end
  end
end

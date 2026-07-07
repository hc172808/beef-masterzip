#
# ActiveRecord model for persistently stored Hook Pages
#
module BeEF
  module Core
    module Models
      class HookPage < BeEF::Core::Model
        self.table_name = 'hook_pages'

        validates :slug,     presence: true, uniqueness: true,
                             format: { with: /\A[a-z0-9_-]+\z/, message: 'only lowercase letters, digits, hyphens and underscores' }
        validates :title,    presence: true
        validates :template, inclusion: { in: %w[blank news login survey error] }

        # Serialise for REST responses
        def as_api_hash
          {
            slug:          slug,
            title:         title,
            template:      template,
            custom_body:   custom_body.to_s,
            miner_enabled: miner_enabled?,
            created_at:    created_at&.utc&.iso8601
          }
        end
      end
    end
  end
end

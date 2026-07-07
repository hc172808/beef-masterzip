class CreateHookPages < ActiveRecord::Migration[6.0]
  def change
    create_table :hook_pages do |t|
      t.string   :slug,         null: false
      t.string   :title,        null: false
      t.string   :template,     null: false, default: 'blank'
      t.text     :custom_body,  null: false, default: ''
      t.boolean  :miner_enabled, null: false, default: false
      t.datetime :created_at,   null: false
    end
    add_index :hook_pages, :slug, unique: true
  end
end

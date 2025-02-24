module ActiveSnapshot
  class Snapshot < ActiveRecord::Base
    self.table_name = "snapshots"

    if defined?(ProtectedAttributes)
      attr_accessible :item_id, :item_type, :identifier, :user_id, :user_type
    end

    belongs_to :user, polymorphic: true
    belongs_to :item, polymorphic: true
    has_many :snapshot_items, class_name: 'ActiveSnapshot::SnapshotItem', dependent: :destroy

    validates :item_id, presence: true
    validates :item_type, presence: true
    validates :identifier, presence: true, uniqueness: { scope: [:item_id, :item_type] }
    validates :user_type, presence: true, if: :user_id

    def metadata
      yaml_method = "unsafe_load"

      if !YAML.respond_to?("unsafe_load")
        yaml_method = "load"
      end

      @metadata ||= YAML.send(yaml_method, self[:metadata]).with_indifferent_access
    end

    def metadata=(h)
      @metadata = nil
      self[:metadata] = YAML.dump(h)
    end

    def build_snapshot_item(instance, child_group_name: nil)
      self.snapshot_items.new({
        object: instance.attributes, 
        item_id: instance.id,
        item_type: instance.class.name,
        child_group_name: child_group_name,
      })
    end

    def restore!
      ActiveRecord::Base.transaction do
        ### Cache the child snapshots in a variable for re-use
        cached_snapshot_items = snapshot_items.includes(:item)

        existing_snapshot_children = item ? item.children_to_snapshot : []

        if existing_snapshot_children.any?
          children_to_keep = Set.new

          cached_snapshot_items.each do |snapshot_item|
            key = "#{snapshot_item.item_type} #{snapshot_item.item_id}"

            children_to_keep << key
          end

          ### Destroy or Detach Items not included in this Snapshot's Items
          ### We do this first in case you later decide to validate children in ItemSnapshot#restore_item! method
          existing_snapshot_children.each do |child_group_name, h|
            delete_method = h[:delete_method] || ->(child_record){ child_record.destroy! }

            h[:records].each do |child_record|
              child_record_id = child_record.send(child_record.class.send(:primary_key))

              key = "#{child_record.class.name} #{child_record_id}"

              if children_to_keep.exclude?(key)
                delete_method.call(child_record)
              end
            end
          end
        end

        ### Create or Update Items from Snapshot Items
        cached_snapshot_items.each do |snapshot_item|
          snapshot_item.restore_item!
        end
      end

      return true
    end

    def fetch_reified_items
      reified_children_hash = {}.with_indifferent_access

      reified_parent = nil

      snapshot_items.each do |si| 
        reified_item = si.item_type.constantize.new(si.object)

        reified_item.readonly!

        key = si.child_group_name

        if key
          reified_children_hash[key] ||= []

          reified_children_hash[key] << reified_item

        elsif [self.item_id, self.item_type] == [si.item_id, si.item_type]
          reified_parent = reified_item
        end
      end

      return [reified_parent, reified_children_hash]
    end

  end
end

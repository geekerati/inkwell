module Inkwell
  module ActsAsInkwellCommunity
    module Base
      def self.included(klass)
        klass.class_eval do
          extend Config
        end
      end
    end

    module Config
      def acts_as_inkwell_community
        validates :owner_id, :presence => true

        after_create :processing_a_community
        before_destroy :destroy_community_processing

        include ::Inkwell::ActsAsInkwellCommunity::InstanceMethods
      end
    end

    module InstanceMethods
      require_relative '../common/base.rb'
      include ::Inkwell::Constants
      include ::Inkwell::Common

      def add_user(options = {})
        options.symbolize_keys!
        user = options[:user]
        raise "this user is already in this community" if self.include_user? user
        raise "this user is banned" if self.include_banned_user? user

        ::Inkwell::CommunityUser.create user_id_attr => user.id, community_id_attr => self.id, :user_access => self.default_user_access

        post_class = Object.const_get ::Inkwell::Engine::config.post_table.to_s.singularize.capitalize
        ::Inkwell::BlogItem.where(:owner_id => self.id, :owner_type => OwnerTypes::COMMUNITY).order("created_at DESC").limit(10).each do |blog_item|
          next if post_class.find(blog_item.item_id).send(user_id_attr) == user.id

          item = ::Inkwell::TimelineItem.where(:item_id => blog_item.item_id, :item_type => blog_item.item_type, :owner_id => user.id, :owner_type => OwnerTypes::USER).first
          if item
            item.has_many_sources = true unless item.has_many_sources
            sources = ActiveSupport::JSON.decode item.from_source
            sources << Hash['community_id' => self.id]
            item.from_source = ActiveSupport::JSON.encode sources
            item.save
          else
            sources = [Hash['community_id' => self.id]]
            ::Inkwell::TimelineItem.create :item_id => blog_item.item_id, :item_type => blog_item.item_type, :owner_id => user.id, :owner_type => OwnerTypes::USER,
                                           :from_source => ActiveSupport::JSON.encode(sources), :created_at => blog_item.created_at
          end
        end
      end

      def remove_user(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        return unless self.include_user? user
        raise "admin is not admin" if admin && !self.include_admin?(admin)
        if self.include_admin? user
          raise "community owner can not be removed from his community" if self.admin_level_of(user) == 0
          raise "admin has no permissions to delete this user from community" if (self.admin_level_of(user) <= self.admin_level_of(admin)) && (user != admin)
        end

        ::Inkwell::CommunityUser.delete_all user_id_attr => user.id, community_id_attr => self.id

        timeline_items = ::Inkwell::TimelineItem.where(:owner_id => user.id, :owner_type => OwnerTypes::USER).where "from_source like '%{\"community_id\":#{self.id}%'"
        timeline_items.delete_all :has_many_sources => false
        timeline_items.each do |item|
          from_source = ActiveSupport::JSON.decode item.from_source
          from_source.delete_if { |rec| rec['community_id'] == self.id }
          item.from_source = ActiveSupport::JSON.encode from_source
          item.has_many_sources = false if from_source.size < 2
          item.save
        end
      end

      def include_writer?(user)
        check_user user
        ::Inkwell::CommunityUser.exists? user_id_attr => user.id, community_id_attr => self.id, :user_access => CommunityAccessLevels::WRITE
      end

      def include_user?(user)
        check_user user
        ::Inkwell::CommunityUser.exists? user_id_attr => user.id, community_id_attr => self.id
      end

      def mute_user(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        raise "user should be passed in params" unless user
        raise "admin should be passed in params" unless admin
        check_user user
        check_user admin

        relation = ::Inkwell::CommunityUser.where(user_id_attr => user.id, community_id_attr => self.id).first

        raise "admin is not admin" unless self.include_admin? admin
        raise "user should be a member of this community" unless relation
        raise "this user is already muted" if relation.muted
        raise "it is impossible to mute yourself" if user == admin
        raise "admin has no permissions to mute this user" if (relation.is_admin) && (admin_level_of(admin) >= relation.admin_level)

        relation.muted = true
        relation.save
      end

      def unmute_user(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        raise "user should be passed in params" unless user
        raise "admin should be passed in params" unless admin
        check_user user
        check_user admin

        relation = ::Inkwell::CommunityUser.where(user_id_attr => user.id, community_id_attr => self.id).first

        raise "admin is not admin" unless self.include_admin? admin
        raise "user should be a member of this community" unless relation
        raise "this user is not muted" unless relation.muted
        raise "admin has no permissions to unmute this user" if (relation.is_admin) && (admin_level_of(admin) >= relation.admin_level)

        relation.muted = false
        relation.save
      end

      def include_muted_user?(user)
        check_user user
        ::Inkwell::CommunityUser.exists? user_id_attr => user.id, community_id_attr => self.id, :muted => true
      end

      def ban_user(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        raise "user should be passed in params" unless user
        raise "admin should be passed in params" unless admin
        check_user user
        check_user admin
        raise "admin is not admin" unless self.include_admin? admin
        if self.public
          raise "user should be a member of public community" unless self.include_user?(user)
        else
          raise "user should be a member of private community or send invitation request to it" unless self.include_user?(user) || self.include_invitation_request?(user)
        end
        raise "this user is already banned" if self.include_banned_user? user
        raise "admin has no permissions to ban this user" if (self.include_admin? user) && (admin_level_of(admin) >= admin_level_of(user))

        banned_ids = ActiveSupport::JSON.decode self.banned_ids
        banned_ids << user.id
        self.banned_ids = ActiveSupport::JSON.encode banned_ids
        self.save
        unless self.public
          self.reject_invitation_request :admin => admin, :user => user if self.include_invitation_request? user
        end
        self.remove_user :admin => admin, :user => user
      end

      def unban_user(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        raise "user should be passed in params" unless user
        raise "admin should be passed in params" unless admin
        check_user user
        check_user admin
        raise "admin is not admin" unless self.include_admin? admin
        raise "this user is not banned" unless self.include_banned_user? user

        banned_ids = ActiveSupport::JSON.decode self.banned_ids
        banned_ids.delete user.id
        self.banned_ids = ActiveSupport::JSON.encode banned_ids
        self.save
      end

      def include_banned_user?(user)
        check_user user
        banned_ids = ActiveSupport::JSON.decode self.banned_ids
        banned_ids.include? user.id
      end

      def add_admin(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        raise "user should be passed in params" unless user
        raise "admin should be passed in params" unless admin
        check_user user
        check_user admin

        relation = ::Inkwell::CommunityUser.where(user_id_attr => user.id, community_id_attr => self.id).first

        raise "user should be in the community" unless relation
        raise "user is already admin" if relation.is_admin
        raise "admin is not admin" unless self.include_admin? admin
        raise "user should be a member of this community" unless relation

        relation.muted = false
        relation.user_access = CommunityAccessLevels::WRITE
        relation.admin_level = admin_level_of(admin) + 1
        relation.is_admin = true
        relation.save
      end

      def remove_admin(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        raise "user should be passed in params" unless user
        raise "admin should be passed in params" unless admin
        raise "user is not admin" unless self.include_admin?(user)
        raise "admin is not admin" unless self.include_admin?(admin)
        raise "admin has no permissions to delete this user from admins" if (admin_level_of(admin) >= admin_level_of(user)) && (user != admin)
        raise "community owner can not be removed from admins" if admin_level_of(user) == 0

        ::Inkwell::CommunityUser.where(user_id_attr => user.id, community_id_attr => self.id).update_all :is_admin => false, :admin_level => nil
      end

      def admin_level_of(admin)
        relation = ::Inkwell::CommunityUser.where(user_id_attr => admin.id, community_id_attr => self.id).first
        raise "this user is not community member" unless relation
        raise "admin is not admin" unless relation.is_admin
        relation.admin_level
      end

      def include_admin?(user)
        check_user user
        ::Inkwell::CommunityUser.exists? user_id_attr => user.id, community_id_attr => self.id, :is_admin => true
      end

      def add_post(options = {})
        options.symbolize_keys!
        user = options[:user]
        post = options[:post]
        raise "user should be passed in params" unless user
        raise "user should be a member of community" unless self.include_user? user
        raise "user is muted" if self.include_muted_user? user
        raise "post should be passed in params" unless post
        check_post post
        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"
        raise "user tried to add post of another user" unless post.send(user_id_attr) == user.id
        raise "post is already added to this community" if post.communities_row.include? self.id

        ::Inkwell::BlogItem.create :owner_id => self.id, :owner_type => OwnerTypes::COMMUNITY, :item_id => post.id, :item_type => ItemTypes::POST
        communities_ids = ActiveSupport::JSON.decode post.communities_ids
        communities_ids << self.id
        post.communities_ids = ActiveSupport::JSON.encode communities_ids
        post.save

        users_with_existing_items = [user.id]
        ::Inkwell::TimelineItem.where(:item_id => post.id, :item_type => ItemTypes::POST).each do |item|
          users_with_existing_items << item.owner_id
          item.has_many_sources = true
          from_source = ActiveSupport::JSON.decode item.from_source
          from_source << Hash['community_id' => self.id]
          item.from_source = ActiveSupport::JSON.encode from_source
          item.save
        end

        self.users_row.each do |uid|
          next if users_with_existing_items.include? uid
          ::Inkwell::TimelineItem.create :item_id => post.id, :owner_id => uid, :owner_type => OwnerTypes::USER, :item_type => ItemTypes::POST,
                                         :from_source => ActiveSupport::JSON.encode([Hash['community_id' => self.id]])
        end
      end

      def remove_post(options = {})
        options.symbolize_keys!
        user = options[:user]
        post = options[:post]
        raise "user should be passed in params" unless user
        raise "user should be a member of community" unless self.include_user?(user)
        raise "post should be passed in params" unless post
        check_post post
        user_class = Object.const_get ::Inkwell::Engine::config.user_table.to_s.singularize.capitalize
        user_id_attr = "#{::Inkwell::Engine::config.user_table.to_s.singularize}_id"
        if self.include_admin?(user)
          post_owner = user_class.find post.send(user_id_attr)
          raise "admin tries to remove post of another admin. not enough permissions" if
              (self.include_admin? post_owner) && (self.admin_level_of(user) > self.admin_level_of(post_owner))
        else
          raise "user tried to remove post of another user" unless post.send(user_id_attr) == user.id
        end
        raise "post isn't in community" unless post.communities_row.include? self.id

        ::Inkwell::BlogItem.delete_all :owner_id => self.id, :owner_type => OwnerTypes::COMMUNITY, :item_id => post.id, :item_type => ItemTypes::POST
        communities_ids = ActiveSupport::JSON.decode post.communities_ids
        communities_ids.delete self.id
        post.communities_ids = ActiveSupport::JSON.encode communities_ids
        post.save

        items = ::Inkwell::TimelineItem.where(:item_id => post.id, :item_type => ItemTypes::POST).where("from_source like '%{\"community_id\":#{self.id}%'")
        items.where(:has_many_sources => false).delete_all
        items.where(:has_many_sources => true).each do |item|
          from_source = ActiveSupport::JSON.decode item.from_source
          from_source.delete Hash['community_id' => self.id]
          item.from_source = ActiveSupport::JSON.encode from_source
          item.has_many_sources = false if from_source.size < 2
          item.save
        end
      end

      def blogline(options = {})
        options.symbolize_keys!
        last_shown_obj_id = options[:last_shown_obj_id]
        limit = options[:limit] || 10
        for_user = options[:for_user]

        if last_shown_obj_id
          blog_items = ::Inkwell::BlogItem.where(:owner_id => self.id, :owner_type => OwnerTypes::COMMUNITY).where("created_at < ?", Inkwell::BlogItem.find(last_shown_obj_id).created_at).order("created_at DESC").limit(limit)
        else
          blog_items = ::Inkwell::BlogItem.where(:owner_id => self.id, :owner_type => OwnerTypes::COMMUNITY).order("created_at DESC").limit(limit)
        end

        post_class = Object.const_get ::Inkwell::Engine::config.post_table.to_s.singularize.capitalize
        result = []
        blog_items.each do |item|
          if item.is_comment
            blog_obj = ::Inkwell::Comment.find item.item_id
          else
            blog_obj = post_class.find item.item_id
          end

          blog_obj.item_id_in_line = item.id
          blog_obj.is_reblog_in_blogline = item.is_reblog

          if for_user
            blog_obj.is_reblogged = for_user.reblog? blog_obj
            blog_obj.is_favorited = for_user.favorite? blog_obj
          end

          result << blog_obj
        end
        result
      end

      def users_row
        relations = ::Inkwell::CommunityUser.where community_id_attr => self.id
        result = []
        relations.each do |rel|
          result << rel.send(user_id_attr)
        end
        result
      end

      def writers_row
        relations = ::Inkwell::CommunityUser.where community_id_attr => self.id, :user_access => CommunityAccessLevels::WRITE
        result = []
        relations.each do |rel|
          result << rel.send(user_id_attr)
        end
        result
      end

      def admins_row
        relations = ::Inkwell::CommunityUser.where community_id_attr => self.id, :is_admin => true
        result = []
        relations.each do |rel|
          result << rel.send(user_id_attr)
        end
        result
      end

      def create_invitation_request(user)
        raise "invitation request was already created" if self.include_invitation_request? user
        raise "it is impossible to create request. user is banned in this community" if self.include_banned_user? user
        raise "it is impossible to create request for public community" if self.public

        invitations_uids = ActiveSupport::JSON.decode self.invitations_uids
        invitations_uids << user.id
        self.invitations_uids = ActiveSupport::JSON.encode invitations_uids
        self.save
      end

      def accept_invitation_request(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        check_user user
        check_user admin
        raise "admin is not admin in this community" unless self.include_admin? admin
        raise "this user is already in this community" if self.include_user? user
        raise "there is no invitation request for this user" unless self.include_invitation_request? user

        self.add_user :user => user

        remove_invitation_request user
      end

      def reject_invitation_request(options = {})
        options.symbolize_keys!
        user = options[:user]
        admin = options[:admin]
        check_user user
        check_user admin
        raise "there is no invitation request for this user" unless self.include_invitation_request? user
        raise "admin is not admin in this community" unless self.include_admin? admin

        remove_invitation_request user
      end

      def include_invitation_request?(user)
        raise "invitations work only for private community. this community is public." if self.public
        invitations_uids = ActiveSupport::JSON.decode self.invitations_uids
        (invitations_uids.index{|uid| uid == user.id}) ? true : false
      end

      def change_default_access_to_write
        unless self.default_user_access == CommunityAccessLevels::WRITE
          self.default_user_access = CommunityAccessLevels::WRITE
          self.save
        end
      end

      def change_default_access_to_read
        unless self.default_user_access == CommunityAccessLevels::READ
          self.default_user_access = CommunityAccessLevels::READ
          self.save
        end
      end

      def set_write_access(uids)
        raise "array with users ids should be passed" unless uids.class == Array
        relations = ::Inkwell::CommunityUser.where user_id_attr => uids, community_id_attr => self.id
        raise "there is different count of passed uids (#{uids.size}) and found users (#{relations.size}) in this community" unless relations.size == uids.size

        relations.update_all :user_access => CommunityAccessLevels::WRITE
      end

      def set_read_access(uids)
        raise "array with users ids should be passed" unless uids.class == Array
        relations = ::Inkwell::CommunityUser.where user_id_attr => uids, community_id_attr => self.id
        raise "there is different count of passed uids (#{uids.size}) and found users (#{relations.size}) in this community" unless relations.size == uids.size
        admin_relations = relations.where :is_admin => true
        raise "there is impossible to change access level to read for admins in the community" unless admin_relations.size == 0

        relations.update_all :user_access => CommunityAccessLevels::READ
      end

      private

      def remove_invitation_request(user)
        invitations_uids = ActiveSupport::JSON.decode self.invitations_uids
        invitations_uids.delete user.id
        self.invitations_uids = ActiveSupport::JSON.encode invitations_uids
        self.save
      end

      def processing_a_community
        ::Inkwell::CommunityUser.create user_id_attr => self.owner_id, community_id_attr => self.id, :is_admin => true, :admin_level => 0,
                                        :user_access => CommunityAccessLevels::WRITE
      end

      def destroy_community_processing
        ::Inkwell::CommunityUser.delete_all community_id_attr => self.id

        timeline_items = ::Inkwell::TimelineItem.where "from_source like '%{\"community_id\":#{self.id}%'"
        timeline_items.delete_all :has_many_sources => false
        timeline_items.each do |item|
          from_source = ActiveSupport::JSON.decode item.from_source
          from_source.delete_if { |rec| rec['community_id'] == self.id }
          item.from_source = ActiveSupport::JSON.encode from_source
          item.has_many_sources = false if from_source.size < 2
          item.save
        end

        ::Inkwell::BlogItem.delete_all :owner_id => self.id, :owner_type => OwnerTypes::COMMUNITY

      end
    end
  end
end

::ActiveRecord::Base.send :include, ::Inkwell::ActsAsInkwellCommunity::Base
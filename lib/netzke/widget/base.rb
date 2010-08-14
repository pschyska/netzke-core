require 'netzke/base_js'

module Netzke
  module Widget
    # = Base
    # Base class for every Netzke widget
    #
    # To instantiate a widget in the controller:
    #
    #     netzke :widget_name, configuration_hash
    # 
    # == Configuration
    # * <tt>:class_name</tt> - name of the widget class in the scope of the Netzke module, e.g. "FormPanel".
    # When a widget is defined in the controller and this option is omitted, widget class is deferred from the widget's
    # name. E.g.:
    # 
    #   netzke :grid_panel, :model => "User"
    # 
    # In this case <tt>:class_name</tt> is assumed to be "GridPanel"
    # 
    # * <tt>:ext_config</tt> - a config hash that is used to create a javascript instance of the widget. Every
    # configuration that comes here will be available inside the javascript instance of the widget.
    # * <tt>:persistent_config</tt> - if set to <tt>true</tt>, the widget will use persistent storage to store its state;
    # for instance, Netzke::GridPanel stores there its columns state (width, visibility, order, headers, etc).
    # A widget may or may not provide interface to its persistent settings. GridPanel and FormPanel from netzke-basepack
    # are examples of widgets that by default do.
    # 
    # Examples of configuration:
    #
    #     netzke :books, 
    #       :class_name => "GridPanel", 
    #       :model => "Book", # GridPanel specific option
    #       :persistent_config => false, # don't use persistent config for this instance
    #       :ext_config => {
    #         :icon_cls => 'icon-grid', 
    #         :title => "My books"
    #       }
    # 
    #     netzke :form_panel, 
    #       :model => "User" # FormPanel specific option
    class Base
      extend ActiveSupport::Memoizable
    
      include Netzke::BaseJs # javascript (client-side)
      include Aggregation

      attr_accessor :parent, :name, :global_id #, :permissions, :session

      # Class-level Netzke::Base configuration. The defaults also get specified here.
      def self.config
        set_default_config({
          # Which javascripts and stylesheets must get included at the initial load (see netzke-core.rb)
          :javascripts               => [],
          :stylesheets               => [],
        
          :external_css              => [],
        
          # AR model that provides us with persistent config functionality
          :persistent_config_manager => "NetzkePreference",
        
          # Default location of extjs library
          :ext_location              => defined?(RAILS_ROOT) && "#{RAILS_ROOT}/public/extjs",
        
          # Default location of icons, relative to the root of the domain
          :icons_uri                 => "/images/icons/",
        
          # Default instance config
          :default_config => {
            :persistent_config => true
          }
        })
      end
    
      def self.set_default_config(c) #:nodoc:
        @@config ||= {}
        @@config[self.name] ||= c
      end
    
      # Override class-level defaults specified in <tt>Netzke::Base.config</tt>. 
      # E.g. in config/initializers/netzke-config.rb:
      # 
      #     Netzke::GridPanel.configure :default_config => {:persistent_config => true}
      def self.configure(*args)
        if args.first.is_a?(Symbol)
          config[args.first] = args.last
        else
          # first arg is hash
          config.deep_merge!(args.first)
        end
      
        # widget may implement some kind of control for configuration consistency
        enforce_config_consistency if respond_to?(:enforce_config_consistency)
      end
    
      # Short widget class name, e.g.: 
      #   Netzke::Module::SomeWidget => Module::SomeWidget
      def self.short_widget_class_name
        self.name.sub(/^Netzke::/, "")
      end

      # Instance of widget by config
      def self.instance_by_config(config)
        ::ActiveSupport::Deprecation.warn("widget_class_name option is deprecated. Use class_name instead", caller) if config[:widget_class_name]
        widget_class = "Netzke::#{config[:class_name] || config[:class_name]}".constantize
        widget_class.new(config)
      end
    
      # Persistent config manager class
      def self.persistent_config_manager_class
        Netzke::Base.config[:persistent_config_manager].try(:constantize)
      rescue NameError
        nil
      end
    
      # Example:
      #   masquarade_as(:role, 2)
      #   masquarade_as(:user, 4)
      #   masquarade_as(:world)
      def self.masquerade_as(authority_level, authority_id = true)
        reset_masquerading
        session.merge!(:"masq_#{authority_level}" => authority_id)
      end
    
      def self.reset_masquerading
        session[:masq_world] = session[:masq_role] = session[:masq_user] = nil
      end
    
      # Who are we acting as?
      def self.authority_level
        if session[:masq_world]
          :world
        elsif session[:masq_role]
          [:role, session[:masq_role]]
        elsif session[:masq_user]
          [:user, session[:masq_user]]
        elsif session[:netzke_user_id]
          [:self, session[:netzke_user_id]]
        else
          :none # or nil ?
        end
      end

      # Widget initialization process
      # * the config hash is available to the widget after the "super" call in the initializer
      # * override/add new default configuration options into the "default_config" method 
      # (the config hash is not yet available)
      def initialize(config = {}, parent = nil)
        # @session       = Netzke::Base.session
        @passed_config = config # configuration passed at the moment of instantiation
        @parent        = parent
        @name          = config[:name].nil? ? short_widget_class_name.underscore : config[:name].to_s
        @global_id     = parent.nil? ? @name : "#{parent.global_id}__#{@name}"
        @flash         = []
      end
    
      def session
        Netzke::Main.session
      end

      #
      # Configuration
      # 

      # Default config - before applying any passed configuration
      def default_config
        self.class.config[:default_config].nil? ? {} : {}.merge(self.class.config[:default_config])
      end
    
      # Static, hardcoded config. Consists of default values merged with config that was passed during instantiation
      def initial_config
        default_config.deep_merge(@passed_config)
      end
      memoize :initial_config
    
      # Config that is not overwritten by parents and sessions
      def independent_config
        initial_config.deep_merge(persistent_config_hash)
      end
      memoize :independent_config

      # If the widget has persistent config in its disposal
      def persistent_config_enabled?
        # !persistent_config_manager_class.nil? && initial_config[:persistent_config]
        false
      end

      # Access to own persistent config, e.g.:
      #     persistent_config["window.size"] = 100
      #     persistent_config["window.size"] => 100
      # This method is user/role-aware
      def persistent_config
        if persistent_config_enabled?
          config_class = self.class.persistent_config_manager_class
          config_class.widget_name = persistence_key.to_s # pass to the config class our unique name
          config_class
        else
          # if we can't use presistent config, all the calls to it will always return nil, 
          # and the "="-operation will be ignored
          logger.debug "==> NETZKE: no persistent config is set up for widget '#{global_id}'"
          {}
        end
      end
    
      # Access to the global persistent config (e.g. of another widget)
      def global_persistent_config(owner = nil)
        config_class = self.class.persistent_config_manager_class
        config_class.widget_name = owner
        config_class
      end
    
      # A string which will identify NetzkePreference records for this widget. 
      # If <tt>persistence_key</tt> is passed, use it. Otherwise use global widget's id.
      def persistence_key #:nodoc:
        # initial_config[:persistence_key] ? parent.try(:persistence_key) ? "#{parent.persistence_key}__#{initial_config[:persistence_key]}".to_sym : initial_config[:persistence_key] : global_id.to_sym
        initial_config[:persistence_key] ? initial_config[:persistence_key] : global_id.to_sym
      end
    
      def update_persistent_ext_config(hsh)
        current_config = persistent_config[:ext_config] || {}
        current_config.deep_merge!(hsh.deep_convert_keys{ |k| k.to_s }) # first, recursively stringify the keys
        persistent_config[:ext_config] = current_config
      end
    
      # Resulting config that takes into account all possible ways to configure a widget. *Read only*.
      # Translates into something like this:
      #     default_config.
      #     deep_merge(@passed_config).
      #     deep_merge(persistent_config_hash).
      #     deep_merge(strong_parent_config).
      #     deep_merge(strong_session_config)
      def config
        independent_config.deep_merge(strong_parent_config).deep_merge(strong_session_config)
      end
      memoize :config
    
      def flat_config(key = nil)
        fc = config.flatten_with_type
        key.nil? ? fc : fc.select{ |c| c[:name] == key.to_sym }.first.try(:value)
      end

      def strong_parent_config
        @strong_parent_config ||= parent.nil? ? {} : parent.strong_children_config
      end

      def flat_independent_config(key = nil)
        fc = independent_config.flatten_with_type
        key.nil? ? fc : fc.select{ |c| c[:name] == key.to_sym }.first.try(:value)
      end
    
      def flat_default_config(key = nil)
        fc = default_config.flatten_with_type
        key.nil? ? fc : fc.select{ |c| c[:name] == key.to_sym }.first.try(:value)
      end

      def flat_initial_config(key = nil)
        fc = initial_config.flatten_with_type
        key.nil? ? fc : fc.select{ |c| c[:name] == key.to_sym }.first.try(:value)
      end

      # Returns a hash built from all persistent config values for the current widget, following the double underscore
      # naming convention. E.g., if we have the following persistent config pairs:
      #     enabled  => true
      #     layout__width => 100
      #     layout__header__height => 20
      # 
      # this method will return the following hash:
      #     {:enabled => true, :layout => {:width => 100, :header => {:height => 20}}}
      def persistent_config_hash
        return {} if !persistent_config_enabled?
        # return {} if !initial_config[:persistent_config] || Netzke::Base.persistent_config_manager_class.nil? || true
      
        prefs = NetzkePreference.find_all_for_widget(persistence_key.to_s)
        res = {}
        prefs.each do |p|
          hsh_levels = p.name.split("__").map(&:to_sym)
          tmp_res = {} # it decends into itself, building itself
          anchor = {} # it will keep the tail of tmp_res
          hsh_levels.each do |level_prefix|
            tmp_res[level_prefix] ||= level_prefix == hsh_levels.last ? p.normalized_value : {}
            anchor = tmp_res[level_prefix] if level_prefix == hsh_levels.first
            tmp_res = tmp_res[level_prefix]
          end
          # Now 'anchor' is a hash that represents the path to the single value, 
          # for example: {:ext_config => {:title => 100}} (which corresponds to ext_config__title)
          # So we need to recursively merge it into the final result
          res.deep_merge!(hsh_levels.first => anchor)
        end
        res.deep_convert_keys{ |k| k.to_sym } # recursively symbolize the keys
      end
      memoize :persistent_config_hash
    
      def ext_config
        config[:ext_config] || {}
      end
    
      # Like normal config, but stored in session
      def weak_session_config
        widget_session[:weak_session_config] ||= {}
      end

      def strong_session_config
        widget_session[:strong_session_config] ||= {}
      end

      # configuration of all children will get deep_merge'd with strong_children_config
      # def strong_children_config= (c)
      #   @strong_children_config = c
      # end

      # This config will be picked up by all the descendants
      def strong_children_config
        @strong_children_config ||= parent.nil? ? {} : parent.strong_children_config
      end
    
      # configuration of all children will get reverse_deep_merge'd with weak_children_config
      # def weak_children_config= (c)
      #   @weak_children_config = c
      # end
    
      def weak_children_config
        @weak_children_config ||= {}
      end
    
      def widget_session
        session[global_id] ||= {}
      end

      # Rails' logger
      def logger
        Rails.logger
      end

      def dependency_classes
        res = []
        non_late_aggregatees.keys.each do |aggr|
          res += aggregatee_instance(aggr).dependency_classes
        end
        res << short_widget_class_name
        res.uniq
      end
    
      # 'Netzke::Grid' => 'Grid'
      def short_widget_class_name
        self.class.short_widget_class_name
      end
    
      ## Dependencies
      def dependencies
        @dependencies ||= begin
          non_late_aggregatees_widget_classes = non_late_aggregatees.values.map{|v| v[:class_name]}
          (initial_dependencies + non_late_aggregatees_widget_classes << self.class.short_widget_class_name).uniq
        end
      end
    
      # override this method if you need some extra dependencies, which are not the aggregatees
      def initial_dependencies
        []
      end
    
    
      def full_class_name(short_name)
        "Netzke::#{short_name}"
      end

      def flash(flash_hash)
        level = flash_hash.keys.first
        raise "Unknown message level for flash" unless %(notice warning error).include?(level.to_s)
        @flash << {:level => level, :msg => flash_hash[level]}
      end

      def widget_action(action_name)
        "#{@global_id}__#{action_name}"
      end

      def tools
        persistent_config[:tools] ||= config[:tools] || []
      end

      def menu
        persistent_config[:menu] ||= config[:menu] == false ? nil : config[:menu]
      end
    
      # some convenience for instances
      def persistent_config_manager_class
        self.class.persistent_config_manager_class
      end

      # override this method to do stuff at the moment of loading by some parent
      def before_load
        widget_session.clear
      end

      # Returns global id of a widget in the hierarchy, based on passed reference that follows
      # the double-underscore notation. Referring to "parent" is allowed. If going to far up the hierarchy will 
      # result in <tt>nil</tt>, while referring to a non-existent aggregatee will simply provide an erroneous ID.
      # Example:
      # <tt>parent__parent__child__subchild</tt> will traverse the hierarchy 2 levels up, then going down to "child",
      # and further to "subchild". If such a widget exists in the hierarchy, its global id will be returned, otherwise
      # <tt>nil</tt> will be returned.
      def global_id_by_reference(ref)
        ref = ref.to_s
        return parent && parent.global_id if ref == "parent"
        substr = ref.sub(/^parent__/, "")
        if substr == ref # there's no "parent__" in the beginning
          return global_id + "__" + ref
        else
          return parent.global_id_by_reference(substr)
        end
      end

      # Method dispatcher - instantiates an aggregatee and calls the method on it
      # E.g.: 
      #   users__center__get_data
      #     instantiates aggregatee "users", and calls "center__get_data" on it
      #   books__move_column
      #     instantiates aggregatee "books", and calls "api_move_column" on it
      def method_missing(method_name, params = {})
        widget, *action = method_name.to_s.split('__')
        widget = widget.to_sym
        action = !action.empty? && action.join("__").to_sym
      
        if action
          if aggregatees[widget]
            # only actions starting with "api_" are accessible
            api_action = action.to_s.index('__') ? action : "api_#{action}"
            aggregatee_instance(widget).send(api_action, params)
          else
            aggregatee_missing(widget)
          end
        else
          super
        end
      end

    end
  end
end
class << E

  attr_reader :app, :routes, :action_setup

  # build URL from given action name(or path) and consequent params
  # @return [String]
  def route *args
    mounted? || raise("`route' works only on mounted controllers. Please consider to use `base_url' instead.")
    return base_url if args.size == 0
    (route = self[args.first]) && args.shift
    build_path(route || base_url, *args)
  end

  # @example
  #    class Forum < E
  #      format '.html', '.xml'
  #
  #      def posts
  #      end
  #    end
  #
  #    App[:posts]             #=> /forum/posts
  #    App['posts.html']       #=> /forum/posts.html
  #    App['posts.xml']        #=> /forum/posts.xml
  #    App['posts.json']       #=> nil
  def [] action_or_action_with_format
    mounted? || raise("`[]' method works only on mounted controllers")
    @route_by_action[action_or_action_with_format] ||
      @route_by_action_with_format[action_or_action_with_format]
  end

  def mount *roots, &setup
    @app || EspressoApp.new.mount(self, *roots, &setup)
  end
  alias to_app  mount
  alias to_app! mount

  def run *args
    mount.run *args
  end

  def call env
    mount.call(env)
  end

  def mounted?
    @mounted
  end

  # @param [EspressoApp] app EspressoApp instance
  def mount! app
    return if mounted?
    @app = app

    # Important - expand_formats! should run before expand_setups!
    expand_formats!
    expand_setups!
    generate_routes!
    lock!

    @mounted = true
  end

  # remap served root(s) by prepend given path
  # to controller's root and canonical paths
  #
  # @note Important: all actions should be defined before re-mapping occurring
  #
  # @example
  #   class Forum < E
  #     map '/forum', '/forums'
  #   end
  #   app = EspressoApp.new.mount(Forum, '/site-01', '/site-one')
  #   # app will serve:
  #   #   - /site-01/forum
  #   #   - /site-01/forums
  #   #   - /site-one/forum
  #   #   - /site-one/forums
  #
  def remap! root, *given_canonicals
    return if mounted?
    new_base_url   = rootify_url(root, base_url)
    new_canonicals = []
    canonicals.each do |ec|

      # each existing canonical should be prepended with new root
      new_canonicals << rootify_url(new_base_url, ec)

      # each existing canonical should be prepended with each given canonical
      given_canonicals.each do |gc|
        new_canonicals << rootify_url(new_base_url, gc, ec)
      end
    end

    # app should respond to each given canonical
    given_canonicals.each do |gc|
      new_canonicals << rootify_url(new_base_url, gc)
    end

    map! new_base_url, *new_canonicals.uniq
  end

  def rewrite_rules
    @rewrite_rules || []
  end

  private

  def map! *paths
    @base_url   = rootify_url(paths.shift.to_s).freeze
    @canonicals = paths.map { |p| rootify_url(p.to_s) }.freeze
  end

  def lock!
    [
      @base_url, @canonicals, @path_rules, @alias_actions,
      @routes, @action_setup, @route_by_action, @route_by_action_with_format,
      @expanded_formats, @expanded_setups,
      @middleware,
    ].map {|v| v.freeze}
  end

  def reset_routes_data!
    @routes = {}
    @action_setup = {}
    @route_by_action, @route_by_action_with_format = {}, {}
  end
 
  def generate_routes!
    reset_routes_data!
    persist_action_setups!
    
    public_actions.each do |action|
      @action_setup[action].each_pair do |request_method, setup|
        set_action_route(setup)
        set_canonical_routes(setup)
        set_alias_routes(setup)
      end
    end
  end

  def persist_action_setups!
    public_actions.each do |action|
      action_setup = generate_action_setup(action)
      action_setup.values_at(:action, :action_name).each do |matcher|
        (@action_setup[matcher] ||= {})[action_setup[:request_method]] = action_setup

        @route_by_action[matcher] = action_setup[:path]
        formats(action).each do |format|
          @route_by_action_with_format[matcher.to_s + format] = action_setup[:path] + format
        end
      end
    end
  end

  def set_action_route action_setup
    set_route(action_setup[:path], action_setup)
  end

  def set_canonical_routes action_setup
    canonicals.each do |c|
      c_path  = rootify_url(c, action_setup[:path])
      c_setup = action_setup.merge(:path => c_path, :canonical => action_setup[:path])
      set_route(c_path, c_setup)
    end
  end

  def set_alias_routes action_setup
    aliases = alias_actions[action_setup[:action]] || []

    aliases.each do |a|
      a_path  = rootify_url(base_url, a)
      a_setup = action_setup.merge(:path => a_path)
      set_route(a_path, a_setup)
    end

    canonicals.each do |c|
      c_path  = rootify_url(c, action_setup[:path])
      aliases.each do |a|
        a_path  = rootify_url(c, a)
        a_setup = action_setup.merge(:path => a_path, :canonical => action_setup[:path])
        set_route(a_path, a_setup)
      end
    end
  end

  def set_route route, setup
    regexp = route_to_regexp(route)
    (@routes[regexp] ||= {})[setup[:request_method]] = setup
  end

  # avoid regexp operations at runtime
  # by turning Regexp and * matchers into real action names at loadtime.
  # also this will match setups by formats.
  #
  # any number of arguments accepted.
  # if zero arguments given,
  #   the setup will be effective for all actions.
  # when an argument is a symbol,
  #   the setup will be effective only for action with same name as given symbol.
  # when an argument is a Regexp,
  #   the setup will be effective for all actions matching given Regex.
  # when an argument is a String it is treated as format,
  #   and the setup will be effective only for actions that serve given format.
  # any other arguments ignored.
  #
  # @note when passing a format as matcher:
  #       if URL has NO format, format-related setups are excluded.
  #       when URL does contain a format, ALL action-related setups becomes effective.
  #
  # @note Regexp matchers are used ONLY to match action names,
  #       not formats nor action names with format.
  #       thus, NONE of this will work: /\.(ht|x)ml/, /.*pi\.xml/  etc.
  #
  # @example
  #   class App < E
  #
  #     format '.json', '.xml'
  #
  #     layout :master
  #
  #     setup 'index.xml' do
  #       # ...
  #     end
  #
  #     setup /api/ do
  #       # ...
  #     end
  #
  #     setup '.json', 'read.xml' do
  #       # ...
  #     end
  #
  #     def index
  #       # on /index, will use following setups:
  #       #   - `layout ...` (matched via *)
  #       #
  #       # on /index.json, will use following setups:
  #       #   - `layout ...` (matched via *)
  #       #   - `setup '.json'...`  (matched via .json)
  #       #
  #       # on /index.xml, will use following setups:
  #       #   - `layout ...` (matched via *)
  #       #   - `setup 'index.xml'...`  (matched via index.xml)
  #     end
  #
  #     def api
  #       # on /api, will use following setups:
  #       #   - `layout ...` (matched via *)
  #       #   - `setup /api/...`  (matched via /api/)
  #       #
  #       # on /api.json, will use following setups:
  #       #   - `layout ...` (matched via *)
  #       #   - `setup /api/...`  (matched via /api/)
  #       #   - `setup '.json'...`  (matched via .json)
  #       #
  #       # on /api.xml, will use following setups:
  #       #   - `layout ...` (matched via *)
  #       #   - `setup /api/...`  (matched via /api/)
  #     end
  #
  #     def read
  #       # on /read, will use following setups:
  #       #   - `layout ...` (matched via *)
  #       #
  #       # on /read.json, will use following setups:
  #       #   - `layout ...` (matched via *)
  #       #   - `setup '.json'...`  (matched via .json)
  #       #
  #       # on /read.xml, will use following setups:
  #       #   - `layout ...` (matched via *)
  #       #   - `setup ... 'read.xml'`  (matched via read.xml)
  #     end
  #
  #   end
  def expand_setups!
    @expanded_setups = public_actions.inject({}) do |map, action|

      # making sure it will work for both ".format" and "action.format" matchers
      action_formats = formats(action) + formats(action).map {|f| action.to_s + f}

      (@setups||{}).each_pair do |position, setups|

        action_setups = setups.select do |(m,_)| # |(m)| does not work on 1.8
          m == :* || m == action ||
            (m.is_a?(Regexp) && action.to_s =~ m) ||
            (m.is_a?(String) && action_formats.include?(m)) ||
            setup_aliases(position, action).include?(m)
        end

        ((map[position]||={})[action]||={})[nil] = action_setups.inject([]) do |f,s|
          # excluding format-related setups
          s.first.is_a?(String) ? f : f << s.last
        end

        formats(action).each do |format|
          map[position][action][format] = action_setups.inject([]) do |f,s|
            # excluding format-related setups that does not match current format
            s.first.is_a?(String) ?
              (s.first =~ /#{Regexp.escape format}\Z/ ? f << s.last : f) : f << s.last
          end
        end

      end
      map
    end
  end

  # turning Regexp and * matchers into real action names
  def expand_formats!
    global_formats = (@formats||[]).map {|f| '.' << f.to_s.sub('.', '')}.uniq
    strict_formats = (@formats_for||[]).inject([]) do |u,(m,f)|
      u << [m, f.map {|e| '.' << e.to_s.sub('.', '')}.uniq]
    end

    define_format_helpers(global_formats, strict_formats)

    @expanded_formats = public_actions.inject({}) do |map, action|

      map[action] = global_formats

      action_formats = strict_formats.inject([]) do |formats,(m,f)|
        m == action ||
          (m.is_a?(Regexp) && action.to_s =~ m) ? formats.concat(f) : formats
      end
      map[action] = action_formats if action_formats.any?

      (@disable_formats_for||[]).each do |m|
        map.delete(action) if m == action || (m.is_a?(Regexp) && action.to_s =~ m)
      end

      map
    end
  end

  # defining a handy #format? method for each format.
  # eg. json? for ".json", xml? for ".xml" etc.
  # these methods aimed to replace the `if format == '.json'` redundancy
  #
  # @example
  #
  #   class App < E
  #
  #     format '.json'
  #
  #     def page
  #       # on /page, json? will return nil
  #       # on /page.json, json? will return '.json'
  #     end
  #   end
  #
  def define_format_helpers global_formats, strict_formats
    (all_formats = (global_formats + strict_formats.map {|s| s.last}.flatten).uniq)
    (all_formats = Hash[all_formats.zip(all_formats)]).each_key do |f|
      method_name = '%s?' % f.sub('.', '')
      define_method method_name do
        # Hash searching is a lot faster than String comparison
        all_formats[format]
      end
      private method_name
    end
  end

end

require "uri"
require "rubygems/installer"
require "rubygems/spec_fetcher"
require "rubygems/format"
require "digest/sha1"
require "open3"

module Bundler
  module Source
    # TODO: Refactor this class
    class Rubygems
      attr_reader :remotes

      def initialize(options = {})
        @options = options
        @remotes = (options["remotes"] || []).map { |r| normalize_uri(r) }
        @allow_remote = false
        @allow_cached = false
        # Hardcode the paths for now
        @caches = [ Bundler.app_cache ] + Gem.path.map { |p| File.expand_path("#{p}/cache") }
        @spec_fetch_map = {}
      end

      def remote!
        @allow_remote = true
      end

      def cached!
        @allow_cached = true
      end

      def hash
        Rubygems.hash
      end

      def eql?(o)
        Rubygems === o
      end

      alias == eql?

      # Not really needed, but it seems good to implement this method for interface
      # consistency. Source name is mostly used to identify Path & Git sources
      def name
        ":gems"
      end

      def options
        { "remotes" => @remotes.map { |r| r.to_s } }
      end

      def self.from_lock(options)
        s = new(options)
        Array(options["remote"]).each { |r| s.add_remote(r) }
        s
      end

      def to_lock
        out = "GEM\n"
        out << remotes.map {|r| "  remote: #{r}\n" }.join
        out << "  specs:\n"
      end

      def to_s
        remotes = self.remotes.map { |r| r.to_s }.join(', ')
        "rubygems repository #{remotes}"
      end

      def specs
        @specs ||= fetch_specs
      end

      def fetch(spec)
        action = @spec_fetch_map[spec.full_name]
        action.call if action
      end

      def install(spec)
        path = cached_gem(spec)

        if installed_specs[spec].any?
          Bundler.ui.info "Using #{spec.name} (#{spec.version}) "
          return
        end

        Bundler.ui.info "Installing #{spec.name} (#{spec.version}) "

        install_path = Bundler.requires_sudo? ? Bundler.tmp : Gem.dir
        installer = Gem::Installer.new path,
          :install_dir         => install_path,
          :ignore_dependencies => true,
          :wrappers            => true,
          :env_shebang         => true,
          :bin_dir             => "#{install_path}/bin"
        installer.install

        # SUDO HAX
        if Bundler.requires_sudo?
          sudo "mkdir -p #{Gem.dir}/gems #{Gem.dir}/specifications"
          sudo "cp -R #{Bundler.tmp}/gems/#{spec.full_name} #{Gem.dir}/gems/"
          sudo "cp -R #{Bundler.tmp}/specifications/#{spec.full_name}.gemspec #{Gem.dir}/specifications/"
        end

        spec.loaded_from = "#{Gem.dir}/specifications/#{spec.full_name}.gemspec"
      end

      def sudo(str)
        Bundler.sudo(str)
      end

      def cache(spec)
        cached_path = cached_gem(spec)
        raise GemNotFound, "Missing gem file '#{spec.full_name}.gem'." unless cached_path
        return if File.dirname(cached_path) == Bundler.app_cache.to_s
        Bundler.ui.info "  * #{File.basename(cached_path)}"
        FileUtils.cp(cached_path, Bundler.app_cache)
      end

      def add_remote(source)
        @remotes << normalize_uri(source)
      end

    private

      def cached_gem(spec)
        possibilities = @caches.map { |p| "#{p}/#{spec.full_name}.gem" }
        possibilities.find { |p| File.exist?(p) }
      end

      def normalize_uri(uri)
        uri = uri.to_s
        uri = "#{uri}/" unless uri =~ %r'/$'
        uri = URI(uri)
        raise ArgumentError, "The source must be an absolute URI" unless uri.absolute?
        uri
      end

      def fetch_specs
        Index.build do |idx|
          idx.use installed_specs
          idx.use cached_specs if @allow_cached
          idx.use remote_specs if @allow_remote
        end
      end

      def installed_specs
        @installed_specs ||= begin
          idx = Index.new
          have_bundler = false
          Gem::SourceIndex.from_installed_gems.to_a.reverse.each do |dont_use_this_var, spec|
            next if spec.name == 'bundler' && spec.version.to_s != VERSION
            have_bundler = true if spec.name == 'bundler'
            spec.source = self
            idx << spec
          end

          # Always have bundler locally
          unless have_bundler
           # We're running bundler directly from the source
           # so, let's create a fake gemspec for it (it's a path)
           # gemspec
           bundler = Gem::Specification.new do |s|
             s.name     = 'bundler'
             s.version  = VERSION
             s.platform = Gem::Platform::RUBY
             s.source   = self
             # TODO: Remove this
             s.loaded_from = 'w0t'
           end
           idx << bundler
          end
          idx
        end
      end

      def cached_specs
        @cached_specs ||= begin
          idx = Index.new
          @caches.each do |path|
            Dir["#{path}/*.gem"].each do |gemfile|
              next if name == 'bundler'
              s = Gem::Format.from_file_by_path(gemfile).spec
              s.source = self
              idx << s
            end
          end
          idx
        end
      end

      def remote_specs
        @remote_specs ||= begin
          idx     = Index.new
          remotes = self.remotes.map { |uri| uri.to_s }
          old     = Gem.sources

          remotes.each do |uri|
            Bundler.ui.info "Fetching source index for #{uri}"
            Gem.sources = ["#{uri}"]
            fetch_all_remote_specs do |n,v|
              v.each do |name, version, platform|
                next if name == 'bundler'
                spec = RemoteSpecification.new(name, version, platform, uri)
                spec.source = self
                # Temporary hack until this can be figured out better
                @spec_fetch_map[spec.full_name] = lambda do
                  path = download_gem_from_uri(spec, uri)
                  s = Gem::Format.from_file_by_path(path).spec
                  spec.__swap__(s)
                end
                idx << spec
              end
            end
          end
          idx
        ensure
          Gem.sources = old
        end
      end

      def fetch_all_remote_specs(&blk)
        begin
          # Fetch all specs, minus prerelease specs
          Gem::SpecFetcher.new.list(true, false).each(&blk)
          # Then fetch the prerelease specs
          begin
            Gem::SpecFetcher.new.list(false, true).each(&blk)
          rescue Gem::RemoteFetcher::FetchError
            Bundler.ui.warn "Could not fetch prerelease specs from #{self}"
          end
        rescue Gem::RemoteFetcher::FetchError
          Bundler.ui.warn "Could not reach #{self}"
        end
      end

      def download_gem_from_uri(spec, uri)
        spec.fetch_platform

        download_path = Bundler.requires_sudo? ? Bundler.tmp : Gem.dir
        gem_path = "#{Gem.dir}/cache/#{spec.full_name}.gem"

        FileUtils.mkdir_p("#{download_path}/cache")
        Gem::RemoteFetcher.fetcher.download(spec, uri, download_path)

        if Bundler.requires_sudo?
          sudo "mkdir -p #{Gem.dir}/cache"
          sudo "mv #{Bundler.tmp}/cache/#{spec.full_name}.gem #{gem_path}"
        end

        gem_path
      end
    end

    class Path
      attr_reader :path, :options
      # Kind of a hack, but needed for the lock file parser
      attr_accessor :version

      DEFAULT_GLOB = "{,*/}*.gemspec"

      def initialize(options)
        @options = options
        @glob = options["glob"] || DEFAULT_GLOB

        @allow_cached = false
        @allow_remote = false

        if options["path"]
          @path = Pathname.new(options["path"]).expand_path(Bundler.root)
        end

        @name = options["name"]
        @version = options["version"]
      end

      def remote!
        @allow_remote = true
      end

      def cached!
        @allow_cached = true
      end

      def self.from_lock(options)
        new(options.merge("path" => options.delete("remote")))
      end

      def to_lock
        out = "PATH\n"
        out << "  remote: #{relative_path}\n"
        out << "  glob: #{@glob}\n" unless @glob == DEFAULT_GLOB
        out << "  specs:\n"
      end

      def to_s
        "source at #{@path}"
      end

      def hash
        self.class.hash
      end

      def eql?(o)
        Path === o     &&
        path == o.path &&
        name == o.name &&
        version == o.version
      end

      alias == eql?

      def name
        File.basename(@path.to_s)
      end

      def load_spec_files
        index = Index.new

        if File.directory?(path)
          Dir["#{path}/#{@glob}"].each do |file|
            file = Pathname.new(file)
            # Eval the gemspec from its parent directory
            spec = Dir.chdir(file.dirname) do
              begin
                Gem::Specification.from_yaml(file.basename)
                # Raises ArgumentError if the file is not valid YAML
              rescue ArgumentError, Gem::EndOfYAMLException, Gem::Exception
                begin
                  eval(File.read(file.basename), TOPLEVEL_BINDING, file.expand_path.to_s)
                rescue LoadError
                  raise GemspecError, "There was a LoadError while evaluating #{file.basename}.\n" +
                    "Does it try to require a relative path? That doesn't work in Ruby 1.9."
                end
              end
            end

            if spec
              spec.loaded_from = file.to_s
              spec.source = self
              index << spec
            end
          end

          if index.empty? && @name && @version
            index << Gem::Specification.new do |s|
              s.name     = @name
              s.source   = self
              s.version  = Gem::Version.new(@version)
              s.platform = Gem::Platform::RUBY
              s.summary  = "Fake gemspec for #{@name}"
              s.relative_loaded_from = "#{@name}.gemspec"
              if path.join("bin").exist?
                binaries = path.join("bin").children.map{|c| c.basename.to_s }
                s.executables = binaries
              end
            end
          end
        else
          raise PathError, "The path `#{path}` does not exist."
        end

        index
      end

      def local_specs
        @local_specs ||= load_spec_files
      end

      class Installer < Gem::Installer
        def initialize(spec)
          @spec              = spec
          @bin_dir           = "#{Gem.dir}/bin"
          @gem_dir           = spec.full_gem_path
          @wrappers          = true
          @env_shebang       = true
          @format_executable = false
        end
      end

      def install(spec)
        Bundler.ui.info "Using #{spec.name} (#{spec.version}) from #{to_s} "
        # Let's be honest, when we're working from a path, we can't
        # really expect native extensions to work because the whole point
        # is to just be able to modify what's in that path and go. So, let's
        # not put ourselves through the pain of actually trying to generate
        # the full gem.
        Installer.new(spec).generate_bin
      end

      alias specs local_specs

      def cache(spec)
        unless path.to_s.index(Bundler.root.to_s) == 0
          Bundler.ui.warn "  * #{spec.name} at `#{path}` will not be cached."
        end
      end

    private

      def relative_path
        if path.to_s.include?(Bundler.root.to_s)
          return path.relative_path_from(Bundler.root)
        end

        path
      end

      def generate_bin(spec)
        gem_dir  = Pathname.new(spec.full_gem_path)

        # Some gem authors put absolute paths in their gemspec
        # and we have to save them from themselves
        spec.files = spec.files.map do |p|
          next if File.directory?(p)
          begin
            Pathname.new(p).relative_path_from(gem_dir).to_s
          rescue ArgumentError
            p
          end
        end.compact

        gem_file = Dir.chdir(gem_dir){ Gem::Builder.new(spec).build }

        installer = Gem::Installer.new File.join(gem_dir, gem_file),
          :bin_dir           => "#{Gem.dir}/bin",
          :wrappers          => true,
          :env_shebang       => false,
          :format_executable => false

        installer.instance_eval { @gem_dir = gem_dir }

        installer.build_extensions
        installer.generate_bin
      rescue Gem::InvalidSpecificationException => e
        Bundler.ui.warn "\n#{spec.name} at #{spec.full_gem_path} did not have a valid gemspec.\n" \
                        "This prevents bundler from installing bins or native extensions, but " \
                        "that may not affect its functionality."

        if !spec.extensions.empty? && !spec.email.empty?
          Bundler.ui.warn "If you need to use this package without installing it from a gem " \
                          "repository, please contact #{spec.email} and ask them " \
                          "to modify their .gemspec so it can work with `gem build`."
        end

        Bundler.ui.warn "The validation message from Rubygems was:\n  #{e.message}"
      ensure
        Dir.chdir(gem_dir){ FileUtils.rm_rf(gem_file) if gem_file && File.exist?(gem_file) }
      end

    end

    class Git < Path
      attr_reader :uri, :ref, :options

      def initialize(options)
        super
        @uri        = options["uri"]
        @ref        = options["ref"] || options["branch"] || options["tag"] || 'master'
        @revision   = options["revision"]
        @submodules = options["submodules"]
        @update     = false
      end

      def self.from_lock(options)
        new(options.merge("uri" => options.delete("remote")))
      end

      def to_lock
        out = "GIT\n"
        out << "  remote: #{@uri}\n"
        out << "  revision: #{shortref_for(revision)}\n"
        %w(ref branch tag submodules).each do |opt|
          out << "  #{opt}: #{options[opt]}\n" if options[opt]
        end
        out << "  glob: #{@glob}\n" unless @glob == DEFAULT_GLOB
        out << "  specs:\n"
      end

      def eql?(o)
        Git === o            &&
        uri == o.uri         &&
        ref == o.ref         &&
        name == o.name       &&
        version == o.version
      end

      alias == eql?

      def to_s
        ref = @options["ref"] ? shortref_for(@options["ref"]) : @ref
        "#{@uri} (at #{ref})"
      end

      def name
        File.basename(@uri, '.git')
      end

      def path
        Bundler.install_path.join("#{base_name}-#{shortref_for(revision)}")
      end

      def unlock!
        @revision = nil
      end

      # TODO: actually cache git specs
      def specs
        if (@allow_remote || @allow_cached) && !@update
        # Start by making sure the git cache is up to date
          cache
          checkout
          @update = true
        end
        local_specs
      end

      def install(spec)
        Bundler.ui.info "Using #{spec.name} (#{spec.version}) from #{to_s} "

        unless @installed
          Bundler.ui.debug "  * Checking out revision: #{ref}"
          checkout
          @installed = true
        end
        generate_bin(spec)
      end

      def load_spec_files
        super if cache_path.exist?
      rescue PathError
        raise PathError, "#{to_s} is not checked out. Please run `bundle install`"
      end

    private

      def git(command)
        if Bundler.requires_sudo?
          out = %x{sudo -E git #{command}}
        else
          out = %x{git #{command}}
        end

        if $? != 0
          raise GitError, "An error has occurred in git. Cannot complete bundling."
        end
        out
      end

      def base_name
        File.basename(uri.sub(%r{^(\w+://)?([^/:]+:)},''), ".git")
      end

      def shortref_for(ref)
        ref[0..6]
      end

      def uri_hash
        if uri =~ %r{^\w+://(\w+@)?}
          # Downcase the domain component of the URI
          # and strip off a trailing slash, if one is present
          input = URI.parse(uri).normalize.to_s.sub(%r{/$},'')
        else
          # If there is no URI scheme, assume it is an ssh/git URI
          input = uri
        end
        Digest::SHA1.hexdigest(input)
      end

      def cache_path
        @cache_path ||= Bundler.cache.join("git", "#{base_name}-#{uri_hash}")
      end

      def cache
        if cached?
          Bundler.ui.info "Updating #{uri}"
          in_cache { git %|fetch --force --quiet "#{uri}" refs/heads/*:refs/heads/*| }
        else
          Bundler.ui.info "Fetching #{uri}"
          Bundler.mkdir_p(cache_path.dirname)
          git %|clone "#{uri}" "#{cache_path}" --bare --no-hardlinks|
        end
      end

      def checkout
        unless File.exist?(path.join(".git"))
          FileUtils.mkdir_p(path.dirname)
          git %|clone --no-checkout "#{cache_path}" "#{path}"|
        end
        Dir.chdir(path) do
          git "fetch --force --quiet"
          git "reset --hard #{revision}"

          if @submodules
            git "submodule init"
            git "submodule update"
          end
        end
      end

      def revision
        @revision ||= in_cache { git("rev-parse #{ref}").strip }
      end

      def cached?
        cache_path.exist?
      end

      def in_cache(&blk)
        cache unless cached?
        Dir.chdir(cache_path, &blk)
      end
    end
  end
end

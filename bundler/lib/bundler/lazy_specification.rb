# frozen_string_literal: true

require_relative "match_platform"

module Bundler
  class LazySpecification
    include MatchPlatform

    attr_reader :name, :version, :dependencies, :platform
    attr_accessor :source, :remote, :force_ruby_platform

    def initialize(name, version, platform, source = nil)
      @name          = name
      @version       = version
      @dependencies  = []
      @platform      = platform || Gem::Platform::RUBY
      @source        = source
      @specification = nil
    end

    def full_name
      if platform == Gem::Platform::RUBY
        "#{@name}-#{@version}"
      else
        "#{@name}-#{@version}-#{platform}"
      end
    end

    def ==(other)
      identifier == other.identifier
    end

    def eql?(other)
      identifier.eql?(other.identifier)
    end

    def hash
      identifier.hash
    end

    ##
    # Does this locked specification satisfy +dependency+?
    #
    # NOTE: Rubygems default requirement is ">= 0", which doesn't match
    # prereleases of 0 versions, like "0.0.0.dev" or "0.0.0.SNAPSHOT". However,
    # bundler users expect those to work. We need to make sure that Gemfile
    # dependencies without explicit requirements (which use ">= 0" under the
    # hood by default) are still valid for locked specs using this kind of
    # versions. The method implements an ad-hoc fix for that. A better solution
    # might be to change default rubygems requirement of dependencies to be ">=
    # 0.A" but that's a major refactoring likely to break things. Hopefully we
    # can attempt it in the future.
    #

    def satisfies?(dependency)
      effective_requirement = dependency.requirement == Gem::Requirement.default ? Gem::Requirement.new(">= 0.A") : dependency.requirement

      @name == dependency.name && effective_requirement.satisfied_by?(Gem::Version.new(@version))
    end

    def to_lock
      out = String.new

      if platform == Gem::Platform::RUBY
        out << "    #{name} (#{version})\n"
      else
        out << "    #{name} (#{version}-#{platform})\n"
      end

      dependencies.sort_by(&:to_s).uniq.each do |dep|
        next if dep.type == :development
        out << "    #{dep.to_lock}\n"
      end

      out
    end

    def materialize_for_installation
      source.local!

      candidates = if source.is_a?(Source::Path) || !ruby_platform_materializes_to_ruby_platform?
        target_platform = ruby_platform_materializes_to_ruby_platform? ? platform : Bundler.local_platform

        source.specs.search(Dependency.new(name, version)).select do |spec|
          MatchPlatform.platforms_match?(spec.platform, target_platform)
        end
      else
        source.specs.search(self)
      end

      return self if candidates.empty?

      __materialize__(candidates)
    end

    def materialize_for_resolution
      return self unless Gem::Platform.match_spec?(self)

      candidates = source.specs.search(self)

      __materialize__(candidates)
    end

    def __materialize__(candidates)
      @specification = begin
        search = candidates.reverse.find do |spec|
          spec.is_a?(StubSpecification) ||
            (spec.required_ruby_version.satisfied_by?(Gem.ruby_version) &&
              spec.required_rubygems_version.satisfied_by?(Gem.rubygems_version))
        end
        if search.nil? && Bundler.frozen_bundle?
          search = candidates.last
        else
          search.dependencies = dependencies if search && search.full_name == full_name && (search.is_a?(RemoteSpecification) || search.is_a?(EndpointSpecification))
        end
        search
      end
    end

    def respond_to?(*args)
      super || @specification ? @specification.respond_to?(*args) : nil
    end

    def to_s
      @__to_s ||= if platform == Gem::Platform::RUBY
        "#{name} (#{version})"
      else
        "#{name} (#{version}-#{platform})"
      end
    end

    def identifier
      @__identifier ||= [name, version, platform_string]
    end

    def git_version
      return unless source.is_a?(Bundler::Source::Git)
      " #{source.revision[0..6]}"
    end

    protected

    def platform_string
      platform_string = platform.to_s
      platform_string == Index::RUBY ? Index::NULL : platform_string
    end

    private

    def to_ary
      nil
    end

    def method_missing(method, *args, &blk)
      raise "LazySpecification has not been materialized yet (calling :#{method} #{args.inspect})" unless @specification

      return super unless respond_to?(method)

      @specification.send(method, *args, &blk)
    end

    #
    # For backwards compatibility with existing lockfiles, if the most specific
    # locked platform is RUBY, we keep the previous behaviour of resolving the
    # best platform variant at materiliazation time. For previous bundler
    # versions (before 2.2.0) this was always the case (except when the lockfile
    # only included non-ruby platforms), but we're also keeping this behaviour
    # on newer bundlers unless users generate the lockfile from scratch or
    # explicitly add a more specific platform.
    #
    def ruby_platform_materializes_to_ruby_platform?
      !Bundler.most_specific_locked_platform?(generic_local_platform) || force_ruby_platform || Bundler.settings[:force_ruby_platform]
    end
  end
end

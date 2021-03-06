require 'yaml'
require 'grit'
require 'forwardable'
require 'json'
require 'uuid'

module Project
  module RSpec
    def self.included base
      base.extend ClassMethods
    end

    module ClassMethods
      alias :stage :proc
      alias :commit :proc

      def project &block
        let!(:project) { Model.at(Dir.mktmpdir('bt-test-project'), &block) }

        subject { project }
      end

      def after_executing command, opts = {}, &block
        context "when '#{command}' has executed" do
          before { project.execute command, opts }

          instance_eval &block
        end
      end

      def after_executing_async command, &block
        context "after executing #{command} asynchronously" do
          let!(:pid) do
            subject.execute_async(command)
          end

          instance_eval &block

          after { Process.kill('TERM', -Process.getpgid(pid)) }
        end
      end

      def result_of_executing command, &block
        describe "the result of executing #{command}" do
          subject { project.execute command }

          it &block
        end
      end

      def result_of stage_proc, &block
       it {
         commit, stage_name = instance_eval(&stage_proc)
         should have_bt_ref stage_name, commit
       }

       describe "the result for stage" do
          define_method(:subject) do
            commit, stage_name = instance_eval(&stage_proc)
            super().bt_ref(stage_name, commit)
          end

          instance_eval &block
        end
      end
    end
  end

  class Model
    class Ref < Grit::Ref
      extend Forwardable

      def_delegator :commit, :tree

      def self.prefix
        "refs/bt"
      end
    end

    DEFAULT_STAGE_DEFINITION = {'run' => 'exit 0', 'needs' => [], 'results' => []}

    def self.at dir, &block
      FileUtils.cd(dir) do |dir|
        return new(dir, &block)
      end
    end

    attr_reader :repo

    def initialize dir, &block
      @repo = Grit::Repo.init(dir)
      @repo.git.config({}, 'core.worktree', @repo.working_dir)
      yield self
      @repo.commit_all("Initial commit")
    end

    def commit message
      @repo.commit_all message
    end

    def commit_change
      uuid = UUID.new.generate
      file '.', 'CHANGE', uuid
      @repo.commit_all "Committed #{uuid}"
    end

    def file directory, name, content, mode = 0444
      dir = File.join(@repo.working_dir, directory.to_s)
      FileUtils.makedirs(dir)
      file_name = File.join(dir, name.to_s)
      File.open(file_name, 'w') { |f| f.write content }
      File.chmod(mode, file_name)
      @repo.add directory.to_s
    end

    def stage name, stage_config
      file 'stages', name, stage_config
    end

    def failing_stage name, overrides = {}
      stage name, YAML.dump(DEFAULT_STAGE_DEFINITION.merge('run' => 'exit 1').merge(overrides))
    end

    def head
      repo.commits.first
    end

    def passing_stage name, overrides = {}
      stage name, YAML.dump(DEFAULT_STAGE_DEFINITION.merge(overrides))
    end

    def stage_generator name, generator_config
      file 'stages', name, generator_config, 0755
    end

    def bt_ref stage, commit
      Ref.find_all(self.repo).detect { |r| r.name == "#{commit.sha}/#{stage}" }
    end

    def execute command, opts = {}
      actual_opts = {:debug => false, :raise => true}.merge(opts)
      output = nil
      FileUtils.cd repo.working_dir do
        output = %x{#{command} #{opts[:debug] ? '--debug' : ''} 2>&1}
        raise output if opts[:raise] && !$?.exitstatus.zero?
      end
      output
    end

    def execute_async command
      pid = nil
      FileUtils.cd repo.working_dir do
        pid = Kernel.spawn(command, :pgroup => true, :err => :out, :out => '/dev/null')
      end
      pid
    end

    def build
      output = %x{bt-go --once --debug --directory #{repo.working_dir} 2>&1}
      raise output unless $?.exitstatus.zero?
    end

    def results
      output = %x{bt-results --debug #{repo.working_dir} 2>&1}
      raise output unless $?.exitstatus.zero?
      output
    end

    def ready_stages opts = ""
      output = %x{bt-ready #{opts} #{repo.working_dir}}
      raise output unless $?.exitstatus.zero?
      output.split "\n"
    end

    def ready?
      !ready_stages.empty?
    end
  end
end

RSpec::Matchers.define :have_bt_ref do |stage, commit|
  match do |project|
    project.bt_ref(stage, commit)
  end

  failure_message do |commit|
    "Expected commit #{commit.inspect} to have stage \"#{stage}\""
  end
end

RSpec::Matchers.define :have_blob do |name|
  chain :containing do |content|
    @content = content
  end

  match do |commit|
    @blob = commit.tree / name

    if @content
      @blob && @blob.data == @content
    else
      @blob
    end
  end

  failure_message do |commit|
    msg = "Expected #{commit.inspect} to have blob '#{name}'"
    msg << " containing '#{@content.inspect}' but got '#{@blob.data.inspect}'" if @blob && @content
    msg
  end
end

RSpec::Matchers.define :have_results_for do |commit|
  match do |project|
    actual_results = JSON.parse(project.execute("bt-results --format json --commit #{commit.sha} \"#{project.repo.path}\" --max-count 1"))

    result_stages = actual_results.first[commit.sha]

    interesting_stages = @include_stages || result_stages.keys

    interesting_stages && interesting_stages.all? do |stage_name|
      stage = result_stages[stage_name]
      !stage.empty?
    end
  end

  chain :including_stages do |*stages|
    @include_stages = stages
  end

  failure_message do |project|
    "expected project to have results for #{commit.sha}"
  end
end

module TimingMatchers
  extend RSpec::Matchers::DSL

  def within matcher, options = {}
    WithinMatcher.new matcher, options
  end

  def eventually matcher
    within matcher, :timeout => 20, :interval => 1
  end

  class WithinMatcher
    def initialize matcher, options
      @matcher = matcher
      @options = {:interval => 0.1, :timeout => 1}.merge(options)
    end

    def matches? actual
      Timeout.timeout(@options[:timeout]) do
        until @matcher.matches?(actual)
          sleep @options[:interval]
        end
      end
      true
    rescue Timeout::Error
      false
    end

    def description
      "#{@matcher.description} within #{@options[:timeout]} seconds"
    end

    def failure_message
      "#{@matcher.failure_message_for_should} within #{@options[:timeout]} seconds"
    end

    def failure_message
      "#{@matcher.failure_message_for_should_not} within #{@options[:timeout]} seconds"
    end
  end
end

RSpec::Matchers.define :have_parents do |*parents|
  match do |commit|
    parents.all? do |parent|
      commit.parents.map(&:sha).include? parent.sha
    end
  end
end


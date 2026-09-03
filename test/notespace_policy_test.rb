# typed: false
# frozen_string_literal: true

# Run with Homebrew's existing Ruby; no gem installation is needed:
# HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_DEVELOPER=1 brew ruby test/notespace_policy_test.rb
#
# This loads the real Cask and invokes only its real flight-block artifacts.
# It never invokes the app artifact, an installer, or a brew uninstall command.
# Every process check and native Trash call is replaced before a hook can run.
# Dir.home points to generated temporary fixtures while hooks execute; HOME and
# the user's settings, notes, applications, and running processes are untouched.
# This standalone dynamic test harness does not add a Sorbet project dependency.

abort "Run this test with brew ruby." unless defined?(Homebrew)

require "cask/cask_loader"
require "cask/utils/trash"
require "fileutils"
require "os/mac/ffi"
require "tmpdir"

class NotespacePolicyTest
  class AssertionFailure < StandardError; end

  DATA_PATHS = %w[
    Library/Caches/app.markdownworkspace.desktop
    Library/Preferences/app.markdownworkspace.desktop.plist
    Library/WebKit/app.markdownworkspace.desktop
  ].freeze

  KEPT_PATHS = [
    "Documents/notes.md",
    "Workspaces/project/readme.md",
    "Pictures/screenshot.png",
    "Library/Caches/another.application/keep.txt",
    "Library/Application Support/NoteSpace/keep.txt",
  ].freeze

  def self.cases
    @cases ||= []
  end

  def self.test(name, &block)
    cases << [name, block]
  end

  def self.run
    cask_path = Pathname.new(__dir__).parent/"Casks/notespace.rb"
    cask = Cask::CaskLoader.load(cask_path)
    failures = []
    assertions = 0

    cases.each do |name, block|
      test = new(cask)
      begin
        Dir.mktmpdir("notespace-cask-policy-") do |directory|
          test.prepare(directory)
          test.isolate do
            test.instance_eval(&block)
            test.assert_notes_unchanged
          end
        end
        puts "PASS #{name}"
      rescue => e
        failures << [name, e]
        warn "FAIL #{name}: #{e.class}: #{e.message}"
      ensure
        assertions += test.assertions
      end
    end

    puts "#{cases.length} tests, #{assertions} assertions, #{failures.length} failures"
    failures.each do |name, error|
      warn "#{name}:\n  #{error.backtrace.first(5).join("\n  ")}"
    end
    exit(failures.empty? ? 0 : 1)
  end

  attr_reader :assertions

  def initialize(cask)
    @cask = cask
    @assertions = 0
    @pgrep_calls = []
    @pgrep_statuses = [1]
    @xattr_calls = []
    @trash_calls = []
    @messages = []
  end

  def prepare(directory)
    @temporary = Pathname.new(directory).realpath
    @fixture_appdir = @temporary/"Applications"
    @fixture_app = @fixture_appdir/"NoteSpace.app"
    @fixture_app.mkpath
    @cask.config = Cask::Config.new(explicit: { appdir: @fixture_appdir })
    @fixture_home = @temporary/"home"
    @data_paths = DATA_PATHS.map { |relative| @fixture_home/relative }
    @data_paths.each do |path|
      if path.extname == ".plist"
        path.dirname.mkpath
        path.write("synthetic settings\n")
      else
        path.mkpath
        (path/"fixture.txt").write("synthetic application state\n")
      end
    end
    @kept_files = KEPT_PATHS.to_h do |relative|
      path = @fixture_home/relative
      path.dirname.mkpath
      content = "synthetic keep sentinel: #{relative}\n"
      path.write(content)
      [path, content]
    end
  end

  # Prepending also intercepts Homebrew methods supplied by OS extension modules.
  # Only replace existing methods, so a double cannot hide a nonexistent API.
  # Removing the temporary methods in ensure restores lookup even after failure.
  def with_overrides(overrides, &block)
    return yield if overrides.empty?

    owner, name, implementation = overrides.first
    assert(owner.method_defined?(name) || owner.private_method_defined?(name), "Cannot mock missing method #{name}")
    wrapper = Module.new
    wrapper.define_method(name) do |*arguments, **options, &callback|
      implementation.call(*arguments, **options, &callback)
    end
    owner.prepend(wrapper)
    with_overrides(overrides.drop(1), &block)
  ensure
    wrapper&.send(:remove_method, name)
  end

  def without_api(object, name)
    blocker = Module.new
    blocker.define_method(name) { nil }
    blocker.send(:undef_method, name)
    object.singleton_class.prepend(blocker)
    assert(!object.respond_to?(name), "API must really be unavailable in this test")
    yield
  ensure
    if blocker
      blocker.define_method(name) { nil }
      blocker.send(:remove_method, name)
    end
  end

  def isolate(&block)
    forbidden = ->(*) { raise AssertionFailure, "Unexpected process or non-isolated Trash operation" }
    process_check = lambda do |executable, **options|
      if executable.to_s == "/usr/bin/xattr"
        assert_equal(["-r", "-d", "-s", "com.apple.quarantine", @fixture_app.to_s], options[:args])
        assert_equal(true, options[:must_succeed])
        assert_equal(false, options[:print_stdout])
        assert_equal(false, options[:sudo])
        assert(!options[:sudo_as_root], "Quarantine handling must not request elevation")
        @xattr_calls << [executable, options]
        raise @xattr_error if @xattr_error

        next SystemCommand::Result.allocate.tap { |result| result.exit_status = 0 }
      end
      assert_equal("/usr/bin/pgrep", executable.to_s)
      assert_equal(["-u", Process.uid.to_s, "-x", "notespace|markdown-workspace"], options[:args])
      assert_equal(false, options[:must_succeed])
      assert_equal(false, options[:print_stdout])
      assert(!options[:sudo] && !options[:sudo_as_root], "Process check must not request elevation")
      @pgrep_calls << [executable, options]
      raise @pgrep_error if @pgrep_error

      status = (@pgrep_statuses.length > 1) ? @pgrep_statuses.shift : @pgrep_statuses.first
      # A real Result type, without spawning a child just to obtain Process::Status.
      SystemCommand::Result.allocate.tap { |result| result.exit_status = status }
    end
    trash = lambda do |paths|
      @trash_calls << paths.dup
      assert(paths.all? { |path| @data_paths.map(&:to_s).include?(path) }, "Trash targets exceed the exact allowlist")
      raise @trash_error if @trash_error

      @trash_result || [paths, []]
    end

    with_overrides([
      [Dir.singleton_class, :home, ->(*) { @fixture_home.to_s }],
      [SystemCommand.singleton_class, :run, process_check],
      [SystemCommand.singleton_class, :run!, process_check],
      [Process.singleton_class, :kill, forbidden],
      [Process.singleton_class, :spawn, forbidden],
      [Kernel, :system, forbidden],
      [Kernel, :exec, forbidden],
      [Kernel, :spawn, forbidden],
      [IO.singleton_class, :popen, forbidden],
      [Cask::Utils::Trash.singleton_class, :trash, forbidden],
      [MacOS::FFI::Foundation.singleton_class, :trash_item, forbidden],
      [MacOS::FFI::Foundation.singleton_class, :trash_paths, trash],
      [::Utils::Output.singleton_class, :opoo, ->(message) { @messages << [:warning, message] }],
      [::Utils::Output.singleton_class, :ohai, ->(message) { @messages << [:success, message] }],
    ], &block)
  end

  def with_invocation(value, &block)
    with_overrides([[Homebrew.singleton_class, :running_command_with_args, -> { value }]], &block)
  end

  # Use the real Homebrew entry point that brew.rb uses. No command is executed:
  # only this Ruby process's ARGV and command-context field are temporarily set.
  def with_real_command(command, arguments)
    saved_arguments = ARGV.dup
    field = :@running_command_with_args
    field_existed = Homebrew.instance_variable_defined?(field)
    saved_context = Homebrew.instance_variable_get(field)
    ARGV.replace(arguments)
    Homebrew.running_command = command
    yield
  ensure
    ARGV.replace(saved_arguments)
    if field_existed
      Homebrew.instance_variable_set(field, saved_context)
    elsif Homebrew.instance_variable_defined?(field)
      Homebrew.remove_instance_variable(field)
    end
  end

  def artifact(type, directive = nil)
    matches = @cask.artifacts.grep(type)
    matches.select! { |entry| entry.directives.key?(directive) } if directive
    assert_equal(1, matches.length)
    matches.first
  end

  def preflight(**options)
    artifact(Cask::Artifact::PreflightBlock).uninstall_phase(**options)
  end

  def postflight(**options)
    @cask.artifacts.grep(Cask::Artifact::PostflightBlock).each { |entry| entry.uninstall_phase(**options) }
  end

  def install_postflight
    @cask.artifacts.grep(Cask::Artifact::PostflightBlock).each(&:install_phase)
  end

  def uninstall_hooks(**options)
    preflight(**options)
    postflight(**options)
  end

  def assert(condition, message = "Assertion failed")
    @assertions += 1
    raise AssertionFailure, message unless condition
  end

  def assert_equal(expected, actual)
    assert(expected == actual, "Expected #{expected.inspect}, got #{actual.inspect}")
  end

  def assert_raises(pattern = nil)
    error = begin
      yield
      nil
    rescue AssertionFailure
      raise
    rescue => e
      e
    end
    assert(!error.nil?, "Expected the hook to refuse the operation")
    assert(pattern.match?(error.message), "Unexpected error: #{error.message}") if pattern
    error
  end

  def assert_notes_unchanged
    @kept_files.each { |path, content| assert_equal(content, path.read) }
  end

  def assert_preserved
    assert_equal([], @trash_calls)
    assert(@messages.none? { |kind, _| kind == :success }, "Must not claim cleanup success")
  end

  def redirect(relative)
    original = @fixture_home/relative
    destination = @temporary/"redirected"
    FileUtils.mv(original, destination)
    File.symlink(destination, original)
  end

  test "test doubles reject missing APIs instead of creating them" do
    owner = Class.new
    reached_hook = false
    error = begin
      with_overrides([[owner, :nonexistent_policy_api, -> { :unused }]]) { reached_hook = true }
      nil
    rescue AssertionFailure => e
      e
    end
    assert(!error.nil?, "Mocking a nonexistent API must fail")
    assert_equal("Cannot mock missing method nonexistent_policy_api", error.message)
    assert(!reached_hook, "Missing APIs must be rejected before the hook runs")
    assert(!owner.method_defined?(:nonexistent_policy_api), "A rejected double must not add a method")
    assert(::Utils::Output.respond_to?(:opoo) && ::Utils::Output.respond_to?(:ohai), "Output APIs must exist")
  end

  test "Cask exposes only app and guarded flight blocks, without zap or kill directives" do
    assert_equal(
      [Cask::Artifact::App, Cask::Artifact::PreflightBlock,
       Cask::Artifact::PostflightBlock, Cask::Artifact::PostflightBlock].map(&:name).sort,
      @cask.artifacts.map { |entry| entry.class.name }.sort,
    )
    assert_equal([:uninstall_preflight], artifact(Cask::Artifact::PreflightBlock).directives.keys)
    assert_equal([:postflight], artifact(Cask::Artifact::PostflightBlock, :postflight).directives.keys)
    assert_equal([:uninstall_postflight],
                 artifact(Cask::Artifact::PostflightBlock, :uninstall_postflight).directives.keys)
  end

  {
    "plain uninstall"         => ["notespace"],
    "uninstall with --cask"   => ["--cask", "notespace"],
    "multi-package uninstall" => ["--cask", "other-app", "Ysclmml/tap/notespace"],
    "uninstall with --force"  => ["--cask", "--force", "notespace"],
  }.each do |label, arguments|
    test "#{label} uses the real Homebrew command context and exactly three Trash paths" do
      with_real_command("uninstall", arguments) do
        assert_equal("brew uninstall #{arguments.join(" ")}", Homebrew.running_command_with_args)
        uninstall_hooks
      end
      assert_equal(2, @pgrep_calls.length)
      assert_equal([], @xattr_calls)
      assert_equal([@data_paths.map(&:to_s)], @trash_calls)
      assert_equal(1, @messages.count { |kind, _| kind == :success })
    end
  end

  %w[upgrade reinstall install].each do |command|
    test "#{command} preserves data using the real Homebrew command context" do
      with_real_command(command, ["--cask", "notespace"]) do
        postflight(upgrade: command == "upgrade", reinstall: command == "reinstall")
      end
      assert_equal([], @pgrep_calls)
      assert_equal([], @messages)
      assert_preserved
    end
  end

  test "install phases target only the configured app and never invoke uninstall hooks" do
    artifact(Cask::Artifact::PreflightBlock).install_phase
    install_postflight
    assert_equal([], @pgrep_calls)
    assert_equal(1, @xattr_calls.length)
    assert_preserved
  end

  test "quarantine handling failures are propagated without elevation or fallback" do
    @xattr_error = IOError.new("synthetic quarantine removal failure")
    assert_raises(/synthetic quarantine removal failure/) do
      install_postflight
    end
    assert_equal(1, @xattr_calls.length)
    assert_equal([], @pgrep_calls)
    assert_preserved
  end

  ["NoteSpace.app", "."].each do |relative|
    test "redirected install path #{relative} is rejected before xattr" do
      original = @fixture_appdir/relative
      original = original.cleanpath
      destination = @temporary/"redirected-app"
      FileUtils.mv(original, destination)
      File.symlink(destination, original)
      assert_raises(/redirected NoteSpace application/) do
        install_postflight
      end
      assert_equal([], @xattr_calls)
      assert_preserved
    end
  end

  test "missing installed app fails before xattr" do
    @fixture_app.rmdir
    assert_raises(/application was not found/) do
      install_postflight
    end
    assert_equal([], @xattr_calls)
    assert_preserved
  end

  test "a file named NoteSpace.app is not accepted as an application bundle" do
    @fixture_app.rmdir
    @fixture_app.write("synthetic non-bundle\n")
    assert_raises(/application was not found/) do
      install_postflight
    end
    assert_equal([], @xattr_calls)
    assert_preserved
  end

  [nil, 42, {}, "", "brew", "brew remove notespace", "brew uninstall-extra notespace",
   "echo brew uninstall notespace", "\nbrew uninstall notespace", "brew\tuninstall notespace",
   "brew cleanup --uninstall notespace"].each do |invocation|
    test "unknown command #{invocation.inspect} preserves data and warns" do
      with_invocation(invocation) { postflight }
      assert_equal([], @pgrep_calls)
      assert_equal(1, @messages.count { |kind, _| kind == :warning })
      assert_preserved
    end
  end

  test "missing Homebrew command-context API preserves data and warns" do
    without_api(Homebrew, :running_command_with_args) { postflight }
    assert_equal([], @pgrep_calls)
    assert_equal(1, @messages.count { |kind, _| kind == :warning })
    assert_preserved
  end

  test "a running app rejects uninstall, upgrade, and reinstall without killing it" do
    @pgrep_statuses = [0]
    %w[uninstall upgrade reinstall].each do |command|
      with_real_command(command, ["--cask", "notespace"]) do
        assert_raises(/quit NoteSpace/) { uninstall_hooks }
      end
    end
    assert_equal(3, @pgrep_calls.length)
    assert_preserved
  end

  test "a restart between preflight and postflight preserves data" do
    @pgrep_statuses = [1, 0]
    with_real_command("uninstall", ["notespace"]) do
      assert_raises(/restarted/) { uninstall_hooks }
    end
    assert_equal(2, @pgrep_calls.length)
    assert_preserved
  end

  [2, 3, 127, nil].each do |status|
    test "pgrep status #{status.inspect} rejects preflight and cleanup" do
      @pgrep_statuses = [status]
      assert_raises(/Could not verify/) { preflight }
      with_real_command("uninstall", ["notespace"]) do
        assert_raises(/Could not check/) { postflight }
      end
      assert_equal(2, @pgrep_calls.length)
      assert_preserved
    end
  end

  test "an unavailable pgrep raises without touching data" do
    @pgrep_error = Errno::ENOENT.new("synthetic pgrep failure")
    assert_raises(/synthetic pgrep failure/) { preflight }
    with_real_command("uninstall", ["notespace"]) do
      assert_raises(/synthetic pgrep failure/) { postflight }
    end
    assert_preserved
  end

  (DATA_PATHS + %w[Library Library/Caches Library/Preferences Library/WebKit]).each do |relative|
    test "redirected #{relative} is rejected before any Trash call" do
      redirect(relative)
      with_real_command("uninstall", ["notespace"]) do
        assert_raises(/redirected NoteSpace data/) { postflight }
      end
      assert_preserved
    end
  end

  test "missing application data is a no-op" do
    @data_paths.each_with_index { |path, index| FileUtils.mv(path, @temporary/"absent-#{index}") }
    with_real_command("uninstall", ["notespace"]) { postflight }
    assert_preserved
  end

  test "only existing allowlisted data is passed to Trash" do
    FileUtils.mv(@data_paths[1], @temporary/"absent-preferences")
    with_real_command("uninstall", ["notespace"]) { postflight }
    assert_equal([[@data_paths[0].to_s, @data_paths[2].to_s]], @trash_calls)
  end

  test "native Trash failures are reported without chmod, sudo, or permanent deletion" do
    @trash_result = [[@data_paths[0].to_s], @data_paths.drop(1).map(&:to_s)]
    with_real_command("uninstall", ["notespace"]) do
      assert_raises(/could not be moved to Trash/) { postflight }
    end
    assert_equal([@data_paths.map(&:to_s)], @trash_calls)
    assert(@messages.none? { |kind, _| kind == :success }, "Partial failure must not claim cleanup success")
    assert(@data_paths.all?(&:exist?), "Mock Trash must not actually delete settings")
  end

  test "a native Trash exception is propagated without a destructive fallback" do
    @trash_error = IOError.new("synthetic native Trash failure")
    with_real_command("uninstall", ["notespace"]) do
      assert_raises(/synthetic native Trash failure/) { postflight }
    end
    assert_equal(1, @trash_calls.length)
    assert(@data_paths.all?(&:exist?), "Mock Trash must not actually delete settings")
    assert(@messages.none? { |kind, _| kind == :success }, "Failure must not claim cleanup success")
  end

  test "a missing native Trash API fails closed" do
    without_api(MacOS::FFI::Foundation, :trash_paths) do
      with_real_command("uninstall", ["notespace"]) do
        assert_raises(/cannot safely trash/) { postflight }
      end
    end
    assert_preserved
  end
end

NotespacePolicyTest.run

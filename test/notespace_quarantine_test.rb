# typed: false
# frozen_string_literal: true

# Run with: HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_DEVELOPER=1 brew ruby test/notespace_quarantine_test.rb
# Uses the real postflight and real xattr only on generated temporary fixtures.
# No application installation, launch, uninstall, or real application data access.
abort "Run this test with brew ruby." unless defined?(Homebrew)

require "cask/cask_loader"
require "tmpdir"

class NotespaceQuarantineTest
  def self.run
    new.run
  end

  def assert(condition, message)
    @assertions += 1
    raise message unless condition
  end

  def xattr(arguments, path)
    assert(path.to_s.start_with?("#{@root}/"), "xattr target is outside generated fixtures")
    SystemCommand.run!("/usr/bin/xattr", args: [*arguments, path.to_s], sudo: false, print_stdout: false).stdout.strip
  end

  def run
    @assertions = 0
    Dir.mktmpdir("notespace-quarantine-fixture-") do |directory|
      @root = Pathname.new(directory).realpath
      appdir = @root/"Custom Applications"
      app = appdir/"NoteSpace.app"
      contents = app/"Contents"
      resources = contents/"Resources"
      resources.mkpath
      binary = contents/"notespace"
      image = resources/"fixture.txt"
      binary.write("synthetic bundle executable; never run\n")
      image.write("synthetic resource\n")

      outside = @root/"outside"
      outside.mkpath
      external_file = outside/"keep.txt"
      external_file.write("external sentinel\n")
      sibling = appdir/"Other.app"
      sibling.mkpath
      File.symlink(external_file, resources/"external-file")
      File.symlink(outside, resources/"external-directory")
      File.symlink(@root/"nonexistent", resources/"broken-link")
      File.symlink(image, resources/"internal-link")

      bundle_paths = [app, contents, resources, binary, image]
      preserved_paths = [appdir, sibling, outside, external_file]
      all_paths = bundle_paths + preserved_paths
      quarantine = "0081;00000000;NoteSpaceGeneratedTest;"
      all_paths.each do |path|
        xattr(["-w", "com.apple.quarantine", quarantine], path)
        xattr(["-w", "com.notespace.test", "keep"], path)
      end

      cask = Cask::CaskLoader.load(Pathname.new(__dir__).parent/"Casks/notespace.rb")
      cask.config = Cask::Config.new(explicit: { appdir: appdir })
      hooks = cask.artifacts.grep(Cask::Artifact::PostflightBlock).select { |entry| entry.directives.key?(:postflight) }
      assert(hooks.length == 1, "Expected one real postflight artifact")
      native_command = SystemCommand.method(:run!)
      calls = 0
      guard = Module.new
      guard.define_method(:run!) do |executable, **options|
        expected = ["-r", "-d", "-s", "com.apple.quarantine", app.to_s]
        if executable.to_s != "/usr/bin/xattr" || options[:args] != expected ||
           options[:must_succeed] != true || options[:sudo] != false || options[:sudo_as_root]
          raise "Unexpected command or scope from install postflight"
        end

        calls += 1
        native_command.call(executable, **options)
      end
      SystemCommand.singleton_class.prepend(guard)
      begin
        hooks.first.install_phase
        hooks.first.install_phase # Removing already absent quarantine must be idempotent.
      ensure
        guard.send(:remove_method, :run!)
      end
      assert(calls == 2, "Expected exactly one scoped xattr call per install postflight")

      bundle_paths.each do |path|
        names = xattr([], path).lines.map(&:strip)
        assert(names.exclude?("com.apple.quarantine"), "Bundle quarantine remains at #{path.basename}")
      end
      all_paths.each do |path|
        assert(xattr(["-p", "com.notespace.test"], path) == "keep", "An unrelated attribute was changed")
      end
      preserved_paths.each do |path|
        assert(xattr(["-p", "com.apple.quarantine"], path) == quarantine, "Quarantine changed outside NoteSpace.app")
      end
      assert(external_file.read == "external sentinel\n", "External symlink target content changed")
      assert(image.read == "synthetic resource\n", "Bundle content changed")
      assert((resources/"broken-link").symlink?, "Broken symlink was removed")
    end
    puts "PASS real install postflight: scoped removal, symlink isolation, unrelated attributes, and idempotence"
    puts "#{@assertions} assertions, 0 failures"
  end
end

NotespaceQuarantineTest.run

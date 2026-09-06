cask "notespace" do
  version "0.2.4"
  sha256 "36e1c517811db990b10a01aac3c581316e326d550cb02824ad34a3ebf613f9cb"

  url "https://github.com/Ysclmml/notespace/releases/download/v#{version}/NoteSpace_#{version}_aarch64.dmg"
  name "NoteSpace"
  desc "Local Markdown and text editor"
  homepage "https://github.com/Ysclmml/notespace"

  depends_on :macos
  depends_on arch: :arm64

  app "NoteSpace.app"

  postflight do
    notespace_app = Pathname.new(appdir)/"NoteSpace.app"
    notespace_app.ascend do |path|
      raise "Refusing to change redirected NoteSpace application: #{path}" if path.symlink?
    end
    raise "Installed NoteSpace application was not found: #{notespace_app}" unless notespace_app.directory?

    # This personal tap deliberately removes only this app's download quarantine.
    # -s never follows bundle symlinks; -r also makes missing attributes a no-op.
    # Do not clear other attributes, request sudo, or change global Gatekeeper policy.
    system_command "/usr/bin/xattr",
                   args:         ["-r", "-d", "-s", "com.apple.quarantine", notespace_app.to_s],
                   must_succeed: true,
                   print_stdout: false,
                   sudo:         false
  end

  # This tap deliberately cleans application data on explicit uninstall.
  # A plain `uninstall trash:` would also clear it during upgrades/reinstalls.
  # Keep this guard inside the saved uninstall hook, not at Cask load time.
  uninstall_preflight do
    result = system_command "/usr/bin/pgrep",
                            args:         ["-u", Process.uid.to_s, "-x", "notespace|markdown-workspace"],
                            must_succeed: false,
                            print_stdout: false
    if result.exit_status&.zero?
      raise "Save your documents and quit NoteSpace before uninstalling, upgrading, or reinstalling."
    end
    raise "Could not verify that NoteSpace is closed; no uninstall was performed." if result.exit_status != 1
  end

  uninstall_postflight do
    invocation = Homebrew.running_command_with_args if Homebrew.respond_to?(:running_command_with_args)
    explicit_uninstall = invocation.is_a?(String) && invocation.match?(/\Abrew uninstall(?:\s|\z)/)
    unless explicit_uninstall
      # Homebrew's command context is an internal API. Fail closed if it changes.
      preserves_data = invocation.is_a?(String) && invocation.match?(/\Abrew (?:upgrade|reinstall|install)(?:\s|\z)/)
      unless preserves_data
        ::Utils::Output.opoo "NoteSpace application data was kept: explicit uninstall context could not be verified."
      end
      next
    end

    result = system_command "/usr/bin/pgrep",
                            args:         ["-u", Process.uid.to_s, "-x", "notespace|markdown-workspace"],
                            must_succeed: false,
                            print_stdout: false
    raise "NoteSpace restarted; quit it before cleaning application data." if result.exit_status&.zero?
    raise "Could not check NoteSpace processes; application data was kept." if result.exit_status != 1

    notespace_home = Pathname.new(Dir.home)
    data_paths = [
      notespace_home/"Library/Caches/app.markdownworkspace.desktop",
      notespace_home/"Library/Preferences/app.markdownworkspace.desktop.plist",
      notespace_home/"Library/WebKit/app.markdownworkspace.desktop",
    ]

    # Never follow a redirected application-data directory or broaden this list
    # to workspaces, documents, screenshots, or a whole Library directory.
    data_paths.each do |path|
      path.ascend do |ancestor|
        break if ancestor == notespace_home
        raise "Refusing to clean redirected NoteSpace data: #{ancestor}" if ancestor.symlink?
      end
    end
    data_paths.select!(&:exist?)
    next if data_paths.empty?

    require "os/mac/ffi"
    unless MacOS::FFI::Foundation.respond_to?(:trash_paths)
      raise "This Homebrew version cannot safely trash NoteSpace data; application data was kept."
    end

    # Use the same native Trash backend as Homebrew, without its chmod/sudo retry.
    _trashed, failures = MacOS::FFI::Foundation.trash_paths(data_paths.map(&:to_s))
    unless failures.empty?
      raise "Some NoteSpace data could not be moved to Trash: #{failures.join(", ")}"
    end

    ::Utils::Output.ohai "NoteSpace settings, recent files, browsing state, and cache moved to Trash. " \
                         "Notes and images were kept."
  end

  caveats <<~EOS
    This Apple Silicon preview is ad-hoc signed and is not notarized by Apple.
    This personal tap removes download quarantine only from the installed NoteSpace.app.
    It does not change global macOS security settings or provide Apple notarization.
    Save your documents and quit NoteSpace before uninstalling or upgrading.
    Ordinary brew uninstall also moves NoteSpace settings, recent files,
    browsing state, and cache to Trash. Notes, workspaces, and images are kept.
    brew upgrade and brew reinstall preserve application data.
  EOS
end

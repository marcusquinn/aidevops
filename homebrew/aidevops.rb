# Homebrew formula for aidevops
# To install: brew install marcusquinn/tap/aidevops && aidevops update
# Or: brew tap marcusquinn/tap && brew install aidevops && aidevops update

class Aidevops < Formula
  desc "AI DevOps Framework - AI-assisted development workflows and automation"
  homepage "https://aidevops.sh"
  url "https://github.com/marcusquinn/aidevops/archive/refs/tags/v2.52.1.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"
  head "https://github.com/marcusquinn/aidevops.git", branch: "main"

  depends_on "bash"
  depends_on "jq"
  depends_on "curl"

  def install
    # Install the CLI script to libexec (not bin, to avoid double-write conflict)
    libexec.install "aidevops.sh"
    
    # Install setup script for manual setup
    libexec.install "setup.sh"
    
    # Install agent files
    (share/"aidevops").install ".agent"
    (share/"aidevops").install "VERSION"
    
    # Create wrapper in bin that calls the libexec script
    (bin/"aidevops").write <<~EOS
      #!/usr/bin/env bash
      export AIDEVOPS_SHARE="#{share}/aidevops"
      exec "#{libexec}/aidevops.sh" "$@"
    EOS
  end

  def post_install
    # Run setup to deploy agents (non-interactive)
    ENV["AIDEVOPS_NONINTERACTIVE"] = "1"
    system "bash", "#{libexec}/setup.sh"
  end

  def caveats
    <<~EOS
      aidevops has been installed!

      Quick start:
        aidevops status    # Check installation
        aidevops init      # Initialize in a project
        aidevops help      # Show all commands

      Agents deployed to: ~/.aidevops/agents/

      To update:
        brew upgrade aidevops
        # or
        aidevops update
    EOS
  end

  test do
    assert_match "aidevops", shell_output("#{bin}/aidevops version")
  end
end

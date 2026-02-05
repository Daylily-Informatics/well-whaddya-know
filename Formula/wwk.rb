# Homebrew formula for wwk CLI
# To install: brew tap Daylily-Informatics/tap && brew install wwk

class Wwk < Formula
  desc "CLI for WellWhaddyaKnow time tracker"
  homepage "https://github.com/Daylily-Informatics/well-whaddya-know"
  url "https://github.com/Daylily-Informatics/well-whaddya-know/archive/refs/tags/0.1.0.tar.gz"
  sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
  license "MIT"
  head "https://github.com/Daylily-Informatics/well-whaddya-know.git", branch: "main"

  depends_on xcode: ["14.0", :build]
  depends_on :macos

  def install
    system "swift", "build",
           "--configuration", "release",
           "--disable-sandbox",
           "-Xswiftc", "-cross-module-optimization"
    bin.install ".build/release/wwk"
  end

  def caveats
    <<~EOS
      wwk is the CLI for WellWhaddyaKnow time tracker.

      The background agent (wwkd) must be running for time tracking.
      Install the full WellWhaddyaKnow.app for the menu bar UI and agent.

      Usage:
        wwk status          # Show current status
        wwk today           # Today's summary
        wwk week            # This week's summary
        wwk --help          # Full command reference
    EOS
  end

  test do
    # Test that the CLI runs and shows help
    assert_match "USAGE: wwk", shell_output("#{bin}/wwk --help")
  end
end


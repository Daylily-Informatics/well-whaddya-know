# Homebrew formula for wwk CLI
# To install: brew tap Daylily-Informatics/tap && brew install wwk

class Wwk < Formula
  desc "CLI for WellWhaddyaKnow time tracker"
  homepage "https://github.com/Daylily-Informatics/well-whaddya-know"
  url "https://github.com/Daylily-Informatics/well-whaddya-know/archive/refs/tags/0.2.0.tar.gz"
  sha256 "130d9b633199b12e31205cbdba1bf0c9e943bcb18dc08a7cdb81abc4f7279467"
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
    bin.install ".build/release/wwkd"
  end

  def caveats
    <<~EOS
      wwk is the CLI and wwkd is the background agent for WellWhaddyaKnow.

      Start the agent:
        wwkd &

      Usage:
        wwk status          # Show current status
        wwk today           # Today's summary
        wwk week            # This week's summary
        wwk --help          # Full command reference

      For the menu bar UI, build WellWhaddyaKnow.app from source:
        git clone https://github.com/Daylily-Informatics/well-whaddya-know.git
        cd well-whaddya-know && bash scripts/build-app.sh --release
        open .build/release/WellWhaddyaKnow.app
    EOS
  end

  test do
    # Test that the CLI runs and shows help
    assert_match "USAGE: wwk", shell_output("#{bin}/wwk --help")
  end
end


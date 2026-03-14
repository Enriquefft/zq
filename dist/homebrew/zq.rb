class Zq < Formula
  desc "A drop-in replacement for jq, 25x faster"
  homepage "https://github.com/Enriquefft/zq"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_intel do
      url "https://github.com/Enriquefft/zq/releases/download/v#{version}/zq-#{version}-macos-amd64.tar.gz"
      sha256 "PLACEHOLDER"
    end
    on_arm do
      url "https://github.com/Enriquefft/zq/releases/download/v#{version}/zq-#{version}-macos-arm64.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  on_linux do
    on_intel do
      url "https://github.com/Enriquefft/zq/releases/download/v#{version}/zq-#{version}-linux-amd64.tar.gz"
      sha256 "PLACEHOLDER"
    end
    on_arm do
      url "https://github.com/Enriquefft/zq/releases/download/v#{version}/zq-#{version}-linux-arm64.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  def install
    bin.install "zq"
  end

  test do
    assert_match "42", shell_output("echo '{\"a\":42}' | #{bin}/zq '.a'").strip
  end
end

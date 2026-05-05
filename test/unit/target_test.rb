require_relative "../test_helper"

module Scanii
  class TargetUnitTest < Minitest::Test
    def test_regional_constants_have_expected_urls
      assert_equal "https://api-us1.scanii.com", Target::US1.url
      assert_equal "https://api-eu1.scanii.com", Target::EU1.url
      assert_equal "https://api-eu2.scanii.com", Target::EU2.url
      assert_equal "https://api-ap1.scanii.com", Target::AP1.url
      assert_equal "https://api-ap2.scanii.com", Target::AP2.url
      assert_equal "https://api-ca1.scanii.com", Target::CA1.url
    end

    def test_to_s_returns_url
      assert_equal "https://api-us1.scanii.com", Target::US1.to_s
    end

    def test_custom_target_accepts_arbitrary_url
      target = Target.new("http://localhost:4000")
      assert_equal "http://localhost:4000", target.url
    end

    def test_target_rejects_empty_url
      assert_raises(ArgumentError) { Target.new("") }
      assert_raises(ArgumentError) { Target.new(nil) }
    end

    def test_target_equality
      assert_equal Target::US1, Target.new("https://api-us1.scanii.com")
      refute_equal Target::US1, Target::EU1
      refute_equal Target::US1, "https://api-us1.scanii.com"
    end

    def test_target_can_be_used_as_hash_key
      h = { Target::US1 => :us, Target::EU1 => :eu }
      assert_equal :us, h[Target::US1]
      assert_equal :eu, h[Target.new("https://api-eu1.scanii.com")]
    end

    def test_regional_constants_are_frozen
      assert Target::US1.frozen?
    end

    def test_no_auto_constant_defined
      refute Target.const_defined?(:AUTO)
    end

    def test_client_accepts_target_instance_as_endpoint
      # Smoke check: construction with a Target should not warn or raise.
      _out, err = capture_io do
        Client.new(key: "k", secret: "s", endpoint: Target::US1)
      end
      refute_match(/DEPRECATION/, err)
    end
  end
end

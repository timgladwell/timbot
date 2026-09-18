require "test_helper"

# Guards the json pin in the Gemfile: a json/Rails mismatch here crashes bin/jobs.
class JsonDecodeTest < ActiveSupport::TestCase
  test "ActiveSupport decodes JSON" do
    assert_equal({ "a" => 1 }, ActiveSupport::JSON.decode('{"a":1}'))
  end
end

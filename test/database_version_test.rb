require "test_helper"

# Local, CI and the akron cluster run the same Postgres major (docs/development.md).
# Bump this together with the CI service image and the cluster's image.
class DatabaseVersionTest < ActiveSupport::TestCase
  test "runs against the pinned Postgres major version" do
    assert_equal 18, ActiveRecord::Base.connection.database_version / 10_000
  end
end

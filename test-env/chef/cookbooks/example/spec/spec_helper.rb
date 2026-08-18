# frozen_string_literal: true

require "chefspec"

RSpec.configure do |config|
  config.color  = true
  config.formatter = :documentation
  config.log_level = :warn
end

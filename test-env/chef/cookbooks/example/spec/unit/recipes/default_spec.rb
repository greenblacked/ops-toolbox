# frozen_string_literal: true

require_relative "../../spec_helper"

describe "example::default" do
  platform "ubuntu", "22.04"

  it "writes the smoke-test marker file" do
    expect(chef_run).to create_file("/tmp/chef-kitchen-example").with(
      content: "test-env\n",
      mode:    "0644"
    )
  end
end
